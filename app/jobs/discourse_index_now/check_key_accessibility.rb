# frozen_string_literal: true

module Jobs
  module DiscourseIndexNow
    class CheckKeyAccessibility < ::Jobs::Base
      sidekiq_options retry: 3

      def execute(args)
        key = args[:key].to_s
        return if key.blank?
        return unless key == SiteSetting.indexnow_api_key

        ::DiscourseIndexNow::KeyAccessibility.refresh(key)
      end
    end
  end
end
