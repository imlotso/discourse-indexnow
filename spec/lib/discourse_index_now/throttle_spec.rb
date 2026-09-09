# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::Throttle do
  before do
    SiteSetting.indexnow_hourly_limit = 200
    SiteSetting.indexnow_daily_limit = 10_000
    Discourse.redis.del(described_class::THROTTLE_UNTIL_KEY)
    described_class.reset!
  end

  # The locale strings name these windows in words ("Last 60 minutes", "Last 24
  # hours"), so they cannot be retuned here alone.
  it "keeps the windows the admin strings describe" do
    expect(described_class::HOURLY_WINDOW_SECONDS).to eq(3600)
    expect(described_class::DAILY_WINDOW_SECONDS).to eq(86_400)
  end

  describe "rolling windows" do
    # The whole point of the rolling window. A counter keyed by clock hour is
    # back at zero the moment the hour ticks over, so the full cap could go out
    # at 1:59 and the full cap again at 2:01.
    it "does not hand back the hourly cap when the clock hour ticks over" do
      freeze_time(Time.zone.parse("2026-03-04 01:59:00")) do
        described_class.record_submission!(200)

        expect(described_class.available_capacity).to eq(0)
      end

      freeze_time(Time.zone.parse("2026-03-04 02:01:00")) do
        expect(described_class.hourly_used).to eq(200)
        expect(described_class.available_capacity).to eq(0)
        expect(described_class.can_submit?(1)).to eq(false)
      end
    end

    it "frees the capacity an hour after it was spent, not on the hour" do
      freeze_time(Time.zone.parse("2026-03-04 01:59:00")) { described_class.record_submission!(200) }

      # 59 minutes later the spend is still inside the window.
      freeze_time(Time.zone.parse("2026-03-04 02:58:00")) do
        expect(described_class.available_capacity).to eq(0)
      end

      freeze_time(Time.zone.parse("2026-03-04 03:00:00")) do
        expect(described_class.hourly_used).to eq(0)
        expect(described_class.available_capacity).to eq(200)
      end
    end

    it "expires each spend on its own schedule rather than all at once" do
      freeze_time(Time.zone.parse("2026-03-04 10:00:00")) { described_class.record_submission!(120) }
      freeze_time(Time.zone.parse("2026-03-04 10:30:00")) { described_class.record_submission!(80) }

      freeze_time(Time.zone.parse("2026-03-04 10:31:00")) do
        expect(described_class.hourly_used).to eq(200)
        expect(described_class.available_capacity).to eq(0)
      end

      # The first spend has aged out; the second has not.
      freeze_time(Time.zone.parse("2026-03-04 11:01:00")) do
        expect(described_class.hourly_used).to eq(80)
        expect(described_class.available_capacity).to eq(120)
      end
    end

    it "rolls the daily window too" do
      freeze_time(Time.zone.parse("2026-03-04 23:30:00")) do
        described_class.record_submission!(10_000)
      end

      freeze_time(Time.zone.parse("2026-03-05 00:30:00")) do
        expect(described_class.daily_used).to eq(10_000)
        expect(described_class.available_capacity).to eq(0)
      end

      freeze_time(Time.zone.parse("2026-03-06 00:30:00")) do
        expect(described_class.daily_used).to eq(0)
      end
    end
  end

  describe ".frees_in" do
    it "counts down to the moment the oldest spend ages out" do
      freeze_time(Time.zone.parse("2026-03-04 10:00:00")) { described_class.record_submission!(200) }

      freeze_time(Time.zone.parse("2026-03-04 10:20:00")) do
        expect(described_class.usage[:hourly_frees_in]).to eq(40 * 60)
      end
    end

    it "points at the oldest spend, not the most recent one" do
      freeze_time(Time.zone.parse("2026-03-04 10:00:00")) { described_class.record_submission!(50) }
      freeze_time(Time.zone.parse("2026-03-04 10:45:00")) { described_class.record_submission!(150) }

      freeze_time(Time.zone.parse("2026-03-04 10:50:00")) do
        # 10 minutes to the 10:00 bucket leaving, not 55 to the 10:45 one.
        expect(described_class.usage[:hourly_frees_in]).to eq(10 * 60)
      end
    end

    it "is nil when nothing has been submitted" do
      expect(described_class.usage[:hourly_frees_in]).to be_nil
      expect(described_class.usage[:daily_frees_in]).to be_nil
    end
  end

  describe ".next_window_delay" do
    it "waits for the exhausted window to free up rather than polling" do
      freeze_time(Time.zone.parse("2026-03-04 10:00:00")) { described_class.record_submission!(200) }

      freeze_time(Time.zone.parse("2026-03-04 10:20:00")) do
        expect(described_class.next_window_delay).to eq(40 * 60)
      end
    end

    it "waits out the longer of the two caps" do
      SiteSetting.indexnow_daily_limit = 200

      freeze_time(Time.zone.parse("2026-03-04 10:00:00")) { described_class.record_submission!(200) }

      freeze_time(Time.zone.parse("2026-03-04 10:20:00")) do
        # The hourly window clears in 40m; the daily one holds the same spend
        # for another 23h40m.
        expect(described_class.next_window_delay).to eq(((24 * 3600) - (20 * 60)))
      end
    end

    it "honours a 429 backoff that outlasts the window" do
      freeze_time do
        described_class.record_submission!(200)
        described_class.throttle_until!(Time.zone.now.to_i + 2.hours.to_i)

        expect(described_class.next_window_delay).to eq(2.hours.to_i)
      end
    end
  end

  describe ".usage" do
    it "reports the counters the throttle actually gates on" do
      described_class.record_submission!(7)

      usage = described_class.usage

      expect(usage[:hourly_used]).to eq(7)
      expect(usage[:daily_used]).to eq(7)
      expect(usage[:hourly_limit]).to eq(200)
      expect(usage[:daily_limit]).to eq(10_000)
      expect(usage[:hourly_window]).to eq(3600)
      expect(usage[:daily_window]).to eq(86_400)
      expect(usage[:throttled_for]).to be_nil
    end

    it "surfaces the backoff IndexNow asked for after a 429" do
      freeze_time do
        described_class.throttle_until!(Time.zone.now.to_i + 90)

        expect(described_class.usage[:throttled_for]).to eq(90)
      end
    end

    # A limit of 0 makes available_capacity return 0, which stops every
    # submission -- it does not lift the cap. The admin page reads these numbers
    # to decide between "full bar" and "unlimited", so the distinction matters.
    it "reports a zero limit as a limit, not as unlimited" do
      SiteSetting.indexnow_hourly_limit = 0

      expect(described_class.usage[:hourly_limit]).to eq(0)
      expect(described_class.available_capacity).to eq(0)
      expect(described_class.can_submit?(1)).to eq(false)
    end
  end

  # Bucket keys are numbered off the epoch, so the counters do not shift when
  # the site's time zone does.
  it "counts the same window whatever the site time zone is" do
    freeze_time(Time.zone.parse("2026-03-04 10:30:00Z")) do
      described_class.record_submission!(42)

      expect(described_class.hourly_used).to eq(42)

      Time.use_zone("Asia/Tokyo") { expect(described_class.hourly_used).to eq(42) }
    end
  end
end
