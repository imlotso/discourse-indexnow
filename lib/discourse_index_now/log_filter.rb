# frozen_string_literal: true

module DiscourseIndexNow
  class LogFilter
    KEYS = %i[status url batch_id trigger_reason response_code locale since until].freeze

    def initialize(params)
      source = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      @values = source.with_indifferent_access.slice(*KEYS)
      @values.each do |key, value|
        raise Discourse::InvalidParameters.new(key) unless value.nil? || value.is_a?(String) || value.is_a?(Numeric)
        @values[key] = value.to_s.strip.presence
      end
      validate!
    end

    def apply(scope = SubmissionLog.all)
      scope = scope.where(status: @values[:status]) if @values[:status]
      scope = scope.where("url ILIKE ?", "%#{@values[:url]}%") if @values[:url]
      scope = scope.where(batch_id: @values[:batch_id]) if @values[:batch_id]
      scope = scope.where(trigger_reason: @values[:trigger_reason]) if @values[:trigger_reason]
      scope = scope.where(response_code: @values[:response_code].to_i) if @values[:response_code]
      scope = scope.where(locale: @values[:locale]) if @values[:locale]
      scope = scope.where("created_at >= ?", @since.beginning_of_day) if @since
      scope = scope.where("created_at < ?", (@until + 1.day).beginning_of_day) if @until
      scope
    end

    def to_h
      @values.compact.to_h
    end

    private

    def validate!
      if @values[:status] && !SubmissionLog.statuses.key?(@values[:status])
        raise Discourse::InvalidParameters.new(:status)
      end
      if @values[:trigger_reason] && !SubmissionLog.trigger_reasons.key?(@values[:trigger_reason])
        raise Discourse::InvalidParameters.new(:trigger_reason)
      end
      if @values[:response_code] && !@values[:response_code].match?(/\A[1-5]\d\d\z/)
        raise Discourse::InvalidParameters.new(:response_code)
      end
      raise Discourse::InvalidParameters.new(:locale) if @values[:locale].to_s.length > 20

      @since = parse_date(:since)
      @until = parse_date(:until)
      raise Discourse::InvalidParameters.new(:until) if @since && @until && @since > @until
    end

    def parse_date(key)
      return if @values[key].blank?

      Date.iso8601(@values[key])
    rescue ArgumentError, TypeError
      raise Discourse::InvalidParameters.new(key)
    end
  end
end
