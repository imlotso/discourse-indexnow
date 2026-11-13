# frozen_string_literal: true

module DiscourseIndexNow
  class BackfillQuery
    def initialize(params)
      source = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      values = source.with_indifferent_access
      @category_id = parse_category(values[:category_id])
      @since = parse_date(values[:since], :since)
      @until = parse_date(values[:until], :until)
      raise Discourse::InvalidParameters.new(:until) if @since && @until && @since > @until
    end

    def scope
      return Topic.none if SiteSetting.login_required?

      topics = Topic.joins(:category).where(
        archetype: Archetype.default,
        deleted_at: nil,
        visible: true,
        categories: { read_restricted: false },
      ).where.not(category_id: Eligibility.excluded_category_ids)

      excluded = Eligibility.excluded_tag_names
      if excluded.present?
        topics = topics.where.not(id: Topic.joins(:tags).where(tags: { name: excluded }).select(:id))
      end
      topics = topics.where(category_id: @category_id) if @category_id
      topics = topics.where("topics.created_at >= ?", @since.beginning_of_day) if @since
      topics = topics.where("topics.created_at < ?", (@until + 1.day).beginning_of_day) if @until
      topics.order(:id)
    end

    def to_h
      { category_id: @category_id, since: @since&.iso8601, until: @until&.iso8601 }.compact
    end

    private

    def parse_category(value)
      return if value.blank?

      id = Integer(value)
      raise ArgumentError unless id.positive?
      id
    rescue ArgumentError, TypeError
      raise Discourse::InvalidParameters.new(:category_id)
    end

    def parse_date(value, name)
      return if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      raise Discourse::InvalidParameters.new(name)
    end
  end
end
