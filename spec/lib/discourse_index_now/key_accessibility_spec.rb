# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::KeyAccessibility do
  let(:key) { "a" * 32 }
  let(:digest) { Digest::SHA256.hexdigest(key) }
  let(:cache_key) { "indexnow:key_check:#{digest}" }
  let(:lock_key) { "indexnow:key_check_lock:#{digest}" }

  before do
    Discourse.redis.del(cache_key)
    Discourse.redis.del(lock_key)
  end

  after do
    Discourse.redis.del(cache_key)
    Discourse.redis.del(lock_key)
  end

  it "returns immediately and enqueues one check on a cold cache" do
    allow(Jobs).to receive(:enqueue)
    allow(Excon).to receive(:get)

    expect(described_class.check(key)).to be_nil
    expect(described_class.check(key)).to be_nil

    expect(Jobs).to have_received(:enqueue).once.with(
      Jobs::DiscourseIndexNow::CheckKeyAccessibility,
      key: key,
    )
    expect(Excon).not_to have_received(:get)
  end

  it "returns cached results without enqueueing" do
    Discourse.redis.setex(cache_key, described_class::CACHE_TTL, "true")
    allow(Jobs).to receive(:enqueue)

    expect(described_class.check(key)).to eq(true)
    expect(Jobs).not_to have_received(:enqueue)
  end

  it "releases the deduplication lock when enqueueing fails" do
    allow(Jobs).to receive(:enqueue).and_raise(StandardError, "queue unavailable")
    allow(Rails.logger).to receive(:warn)

    expect(described_class.check(key)).to be_nil

    expect(Discourse.redis.get(lock_key)).to be_nil
    expect(Rails.logger).to have_received(:warn).with(include("queue unavailable"))
  end

  it "stores a bounded false result when the probe times out" do
    allow(Excon).to receive(:get).and_raise(Excon::Error::Timeout.new("timed out"))
    allow(Rails.logger).to receive(:warn)

    expect(described_class.refresh(key)).to eq(false)
    expect(Discourse.redis.get(cache_key)).to eq("false")
    expect(Discourse.redis.ttl(cache_key)).to be_between(1, described_class::CACHE_TTL)
  end
end
