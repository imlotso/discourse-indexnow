# frozen_string_literal: true

module DiscourseIndexNow
  class KeyAccessibility
    CACHE_TTL = 5.minutes.to_i
    ENQUEUE_LOCK_TTL = 1.minute.to_i

    class << self
      def check(key)
        return false if key.blank?

        cached = Discourse.redis.get(cache_key(key))
        return cached == "true" unless cached.nil?

        enqueue_check(key)
        nil
      end

      def refresh(key)
        return false if key.blank?

        accessible = probe(key)
        Discourse.redis.setex(cache_key(key), CACHE_TTL, accessible.to_s)
        accessible
      rescue Excon::Error => e
        Rails.logger.warn("IndexNow key accessibility check failed: #{e.class}: #{e.message}")
        Discourse.redis.setex(cache_key(key), CACHE_TTL, "false")
        false
      ensure
        Discourse.redis.del(lock_key(key)) if key.present?
      end

      private

      def enqueue_check(key)
        return unless Discourse.redis.set(lock_key(key), "1", nx: true, ex: ENQUEUE_LOCK_TTL)

        Jobs.enqueue(Jobs::DiscourseIndexNow::CheckKeyAccessibility, key: key)
      rescue StandardError => e
        Discourse.redis.del(lock_key(key))
        Rails.logger.warn("Unable to enqueue IndexNow key accessibility check: #{e.class}: #{e.message}")
      end

      def cache_key(key)
        "indexnow:key_check:#{key_digest(key)}"
      end

      def lock_key(key)
        "indexnow:key_check_lock:#{key_digest(key)}"
      end

      def key_digest(key)
        Digest::SHA256.hexdigest(key)
      end

      def probe(key)
        response =
          Excon.get(
            "#{Discourse.base_url}/#{key}.txt",
            connect_timeout: 10,
            read_timeout: 10,
            expects: [200],
          )

        response.body.to_s.strip == key
      rescue Excon::Error::HTTPStatus
        false
      end
    end
  end
end
