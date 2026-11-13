# frozen_string_literal: true

module DiscourseIndexNow
  class Throttle
    THROTTLE_UNTIL_KEY = "indexnow:throttle:until"

    # Both caps are rolling windows rather than calendar buckets.
    #
    # A counter keyed by clock hour resets on the boundary rather than on the
    # age of what it counted, so the whole hourly cap could go out at 1:59 and
    # the whole cap again at 2:01 -- twice the limit inside two minutes. Summing
    # fine-grained buckets that are still inside the window closes that: at 2:01
    # the 1:59 spend is still part of the last-60-minutes total.
    #
    # Resolution is the bucket size, so the hourly cap is exact to the minute
    # and the daily cap to the hour. That holds the memory (60 + 24 keys) and
    # the read (one MGET) fixed no matter how much is submitted, which a log of
    # individual submissions would not.
    HOURLY_WINDOW_SECONDS = 1.hour.to_i
    HOURLY_BUCKET_SECONDS = 1.minute.to_i
    DAILY_WINDOW_SECONDS = 1.day.to_i
    DAILY_BUCKET_SECONDS = 1.hour.to_i

    HOURLY_PREFIX = "indexnow:rate:h"
    DAILY_PREFIX = "indexnow:rate:d"

    # The window check and the reservation must be one Redis operation: two
    # Sidekiq workers can otherwise spend the same remaining quota.
    RESERVE_SCRIPT = <<~LUA
      local now = tonumber(ARGV[1])
      local hourly_limit = tonumber(ARGV[2])
      local daily_limit = tonumber(ARGV[3])
      local requested = tonumber(ARGV[4])
      local hourly_count = tonumber(ARGV[5])
      local hourly_ttl = tonumber(ARGV[6])
      local daily_ttl = tonumber(ARGV[7])
      local blocked_until = tonumber(redis.call('GET', KEYS[1]) or '0')
      if blocked_until > now or hourly_limit <= 0 or daily_limit <= 0 or requested <= 0 then
        return 0
      end

      local hourly_used = 0
      local daily_used = 0
      for i = 2, hourly_count + 1 do
        hourly_used = hourly_used + tonumber(redis.call('GET', KEYS[i]) or '0')
      end
      for i = hourly_count + 2, #KEYS do
        daily_used = daily_used + tonumber(redis.call('GET', KEYS[i]) or '0')
      end

      local granted = math.max(0, math.min(requested, hourly_limit - hourly_used, daily_limit - daily_used))
      if granted > 0 then
        redis.call('INCRBY', KEYS[hourly_count + 1], granted)
        redis.call('EXPIRE', KEYS[hourly_count + 1], hourly_ttl)
        redis.call('INCRBY', KEYS[#KEYS], granted)
        redis.call('EXPIRE', KEYS[#KEYS], daily_ttl)
      end
      return granted
    LUA

    EXTEND_THROTTLE_SCRIPT = <<~LUA
      local current = tonumber(redis.call('GET', KEYS[1]) or '0')
      local requested = tonumber(ARGV[1])
      if requested > current then
        redis.call('SET', KEYS[1], requested)
        return requested
      end
      return current
    LUA

    class << self
      def throttled?
        Time.zone.now.to_i < Discourse.redis.get(THROTTLE_UNTIL_KEY).to_i
      end

      def throttle_until!(timestamp)
        Discourse.redis.eval(
          EXTEND_THROTTLE_SCRIPT,
          keys: [Discourse.redis.namespace_key(THROTTLE_UNTIL_KEY)],
          argv: [timestamp.to_i],
        )
      end

      def retry_delay
        remaining = Discourse.redis.get(THROTTLE_UNTIL_KEY).to_i - Time.zone.now.to_i
        remaining.positive? ? remaining : nil
      end

      def can_submit?(url_count)
        url_count = url_count.to_i
        return false if throttled?

        available_capacity.positive? && url_count <= available_capacity
      end

      def available_capacity(now = Time.zone.now)
        return 0 if throttled?

        hourly_limit = SiteSetting.indexnow_hourly_limit.to_i
        daily_limit = SiteSetting.indexnow_daily_limit.to_i
        return 0 if hourly_limit <= 0 || daily_limit <= 0

        [hourly_limit - hourly_used(now), daily_limit - daily_used(now)].min
      end

      # Count outbound attempts before sending, even if their response fails or
      # times out. A worker that crashes cannot spend the same allowance twice.
      def reserve!(url_count, now = Time.zone.now)
        hourly_keys = window_keys(HOURLY_PREFIX, HOURLY_BUCKET_SECONDS, HOURLY_WINDOW_SECONDS, now)
        daily_keys = window_keys(DAILY_PREFIX, DAILY_BUCKET_SECONDS, DAILY_WINDOW_SECONDS, now)
        keys = [THROTTLE_UNTIL_KEY, *hourly_keys, *daily_keys].map do |key|
          Discourse.redis.namespace_key(key)
        end

        Discourse.redis.eval(
          RESERVE_SCRIPT,
          keys: keys,
          argv: [
            now.to_i,
            SiteSetting.indexnow_hourly_limit.to_i,
            SiteSetting.indexnow_daily_limit.to_i,
            url_count.to_i,
            hourly_keys.size,
            HOURLY_WINDOW_SECONDS + HOURLY_BUCKET_SECONDS,
            DAILY_WINDOW_SECONDS + DAILY_BUCKET_SECONDS,
          ],
        ).to_i
      end

      def hourly_used(now = Time.zone.now)
        window_total(HOURLY_PREFIX, HOURLY_BUCKET_SECONDS, HOURLY_WINDOW_SECONDS, now)
      end

      def daily_used(now = Time.zone.now)
        window_total(DAILY_PREFIX, DAILY_BUCKET_SECONDS, DAILY_WINDOW_SECONDS, now)
      end

      def record_submission!(url_count, now = Time.zone.now)
        url_count = url_count.to_i
        return if url_count <= 0

        hourly = bucket_key(HOURLY_PREFIX, HOURLY_BUCKET_SECONDS, now)
        daily = bucket_key(DAILY_PREFIX, DAILY_BUCKET_SECONDS, now)

        Discourse.redis.multi do |redis|
          redis.incrby(hourly, url_count)
          # One bucket of slack so a bucket is still readable on the last tick
          # that still counts it.
          redis.expire(hourly, HOURLY_WINDOW_SECONDS + HOURLY_BUCKET_SECONDS)
          redis.incrby(daily, url_count)
          redis.expire(daily, DAILY_WINDOW_SECONDS + DAILY_BUCKET_SECONDS)
        end
      end

      # Snapshot of the plugin's own rate counters for the admin page.
      #
      # A rolling window never resets, so there is no countdown to a boundary to
      # report. What an admin can act on is when capacity comes back, which is
      # when the oldest counted bucket ages out of the window -- frees_in below.
      def usage(now = Time.zone.now)
        {
          hourly_used: hourly_used(now),
          hourly_limit: SiteSetting.indexnow_hourly_limit.to_i,
          hourly_window: HOURLY_WINDOW_SECONDS,
          hourly_frees_in:
            frees_in(HOURLY_PREFIX, HOURLY_BUCKET_SECONDS, HOURLY_WINDOW_SECONDS, now),
          daily_used: daily_used(now),
          daily_limit: SiteSetting.indexnow_daily_limit.to_i,
          daily_window: DAILY_WINDOW_SECONDS,
          daily_frees_in: frees_in(DAILY_PREFIX, DAILY_BUCKET_SECONDS, DAILY_WINDOW_SECONDS, now),
          # Set only when IndexNow itself answered 429 with a Retry-After, which
          # is the one part of this that reflects the remote service's limits
          # rather than the plugin's own.
          throttled_for: throttled? ? retry_delay : nil,
        }
      end

      # How long until an exhausted window has room again, in seconds.
      #
      # Capacity returns as the oldest counted bucket falls out of the window,
      # not all at once. nil when nothing is counted: there is nothing to wait
      # for, so the caller has no delay to derive from here.
      def frees_in(prefix, bucket_seconds, window_seconds, now = Time.zone.now)
        keys = window_keys(prefix, bucket_seconds, window_seconds, now)
        values = Discourse.redis.mget(*keys)

        offset = values.index { |value| value.to_i.positive? }
        return if offset.nil?

        # window_keys is oldest first, so offset 0 is the bucket that leaves
        # next. Bucket B leaves once now >= (B * bucket) + window.
        oldest_bucket = first_bucket(bucket_seconds, window_seconds, now) + offset
        (oldest_bucket * bucket_seconds) + window_seconds - now.to_i
      end

      def next_window_delay(now = Time.zone.now)
        delays = [retry_delay]

        hourly_limit = SiteSetting.indexnow_hourly_limit.to_i
        if hourly_limit.positive? && hourly_used(now) >= hourly_limit
          delays << frees_in(HOURLY_PREFIX, HOURLY_BUCKET_SECONDS, HOURLY_WINDOW_SECONDS, now)
        end

        daily_limit = SiteSetting.indexnow_daily_limit.to_i
        if daily_limit.positive? && daily_used(now) >= daily_limit
          delays << frees_in(DAILY_PREFIX, DAILY_BUCKET_SECONDS, DAILY_WINDOW_SECONDS, now)
        end

        # Both caps have to clear, so wait out the longer of them. A limit of 0
        # is not covered by either branch because nothing ages out of a window
        # that admits nothing; that falls through to the poll below, which is
        # what picks the job back up once an admin raises the setting.
        delays.compact.max || 60
      end

      # Drops every counter in both windows. Nothing in the plugin resets a
      # window by hand -- buckets age out on their own -- so this exists to give
      # tests a clean slate.
      def reset!(now = Time.zone.now)
        keys =
          window_keys(HOURLY_PREFIX, HOURLY_BUCKET_SECONDS, HOURLY_WINDOW_SECONDS, now) +
            window_keys(DAILY_PREFIX, DAILY_BUCKET_SECONDS, DAILY_WINDOW_SECONDS, now)

        Discourse.redis.del(*keys)
      end

      # Every bucket still inside the window, oldest first.
      def window_keys(prefix, bucket_seconds, window_seconds, now = Time.zone.now)
        first = first_bucket(bucket_seconds, window_seconds, now)
        count = window_seconds / bucket_seconds

        Array.new(count) { |offset| "#{prefix}:#{first + offset}" }
      end

      private

      def window_total(prefix, bucket_seconds, window_seconds, now)
        keys = window_keys(prefix, bucket_seconds, window_seconds, now)

        Discourse.redis.mget(*keys).sum { |value| value.to_i }
      end

      # Buckets are numbered off the epoch rather than off a formatted clock
      # time, so no part of this depends on the site's time zone.
      def bucket_index(bucket_seconds, now)
        now.to_i / bucket_seconds
      end

      def first_bucket(bucket_seconds, window_seconds, now)
        bucket_index(bucket_seconds, now) - (window_seconds / bucket_seconds) + 1
      end

      def bucket_key(prefix, bucket_seconds, now)
        "#{prefix}:#{bucket_index(bucket_seconds, now)}"
      end
    end
  end
end
