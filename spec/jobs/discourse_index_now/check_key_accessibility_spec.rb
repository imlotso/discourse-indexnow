# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscourseIndexNow::CheckKeyAccessibility do
  let(:key) { "a" * 32 }

  before { SiteSetting.indexnow_api_key = key }

  it "performs the network-backed refresh outside the web request" do
    allow(DiscourseIndexNow::KeyAccessibility).to receive(:refresh)

    described_class.new.execute(key: key)

    expect(DiscourseIndexNow::KeyAccessibility).to have_received(:refresh).with(key)
  end

  it "ignores a stale key after key rotation" do
    allow(DiscourseIndexNow::KeyAccessibility).to receive(:refresh)

    described_class.new.execute(key: "b" * 32)

    expect(DiscourseIndexNow::KeyAccessibility).not_to have_received(:refresh)
  end
end
