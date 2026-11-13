# frozen_string_literal: true

require "rails_helper"

describe DiscourseIndexNow::Client do
  let(:key) { "a" * 32 }
  let(:urls) do
    [
      "https://forum.example.com/t/hello/1",
      "https://forum.example.com/t/hello/1?tl=es",
    ]
  end

  before do
    SiteSetting.indexnow_api_key = key
    allow(Discourse).to receive(:base_url).and_return("https://forum.example.com")
    allow(Discourse).to receive(:current_hostname).and_return("forum.example.com")
  end

  it "submits a batch as JSON" do
    response = double(status: 202)
    allow(Excon).to receive(:post).and_return(response)

    expect(described_class.submit_batch(urls)).to eq(success: true, status: 202)
    expect(Excon).to have_received(:post)
  end

  it "builds the keyLocation and urlList for a batch" do
    payload = JSON.parse(described_class.payload(urls).to_json)

    expect(payload["host"]).to eq("forum.example.com")
    expect(payload["key"]).to eq(key)
    expect(payload["keyLocation"]).to eq("https://forum.example.com/#{key}.txt")
    expect(payload["urlList"]).to eq(urls)
  end

  it "treats non-success HTTP responses as failures" do
    response = double(status: 422)
    error = Excon::Error::UnprocessableEntity.new("Expected [200, 202] <=> Actual: 422")
    allow(error).to receive(:response).and_return(response)
    allow(Excon).to receive(:post).and_raise(error)

    expect(described_class.submit_batch(urls)).to eq(
      success: false,
      status: 422,
      error: "HTTP 422",
    )
  end

  it "returns Retry-After for a 429 response" do
    response = double(status: 429, headers: { "Retry-After" => "120" })
    error = Excon::Error::TooManyRequests.new("Expected [200, 202] <=> Actual: 429")
    allow(error).to receive(:response).and_return(response)
    allow(Excon).to receive(:post).and_raise(error)

    expect(described_class.submit_batch(urls)).to eq(
      success: false,
      status: 429,
      error: "HTTP 429",
      retry_after: 120,
    )
  end

  it "accepts an HTTP date in Retry-After" do
    freeze_time(Time.utc(2026, 1, 1, 12, 0, 0)) do
      response = double(status: 429, headers: { "Retry-After" => "Thu, 01 Jan 2026 12:02:00 GMT" })
      error = Excon::Error::TooManyRequests.new("Expected [200, 202] <=> Actual: 429")
      allow(error).to receive(:response).and_return(response)
      allow(Excon).to receive(:post).and_raise(error)

      expect(described_class.submit_batch(urls)[:retry_after]).to eq(120)
    end
  end

  it "rejects batches larger than the IndexNow limit" do
    expect { described_class.submit_batch(Array.new(10_001) { |i| "https://example.com/#{i}" }) }
      .to raise_error(DiscourseIndexNow::Client::SubmissionError)
  end

  it "converts a timeout into a failure result" do
    allow(Excon).to receive(:post).and_raise(Excon::Error::Timeout.new("timed out"))

    expect(described_class.submit_batch(urls)).to eq(success: false, error: "timed out")
  end

  it "converts a proxy connection failure into a retryable result" do
    allow(Excon).to receive(:post).and_raise(Excon::Error::ProxyConnectionError.new("proxy unavailable"))

    expect(described_class.submit_batch(urls)).to eq(success: false, error: "proxy unavailable")
  end
end
