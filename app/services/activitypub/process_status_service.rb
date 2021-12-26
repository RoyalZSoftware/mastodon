# frozen_string_literal: true

class ActivityPub::ProcessStatusService < BaseService
  include JsonLdHelper

  def call(status, json)
    @json                      = json
    @uri                       = @json['id']
    @status                    = status
    @account                   = status.account
    @media_attachments_changed = false

    return unless expected_type?

    return if already_updated_more_recently?

    # Only allow processing one create/update per status at a time
    RedisLock.acquire(lock_options) do |lock|
      if lock.acquired?
        Status.transaction do
          create_previous_edit!
          update_media_attachments!
          update_poll!
          update_immediate_attributes!
          update_metadata!
          create_edit!
        end

        reset_preview_card!
        broadcast_updates!
      else
        raise Mastodon::RaceConditionError
      end
    end
  end

  private

  def update_media_attachments!
    previous_media_attachments = @status.media_attachments.to_a
    next_media_attachments     = []

    as_array(@json['attachment']).each do |attachment|
      next if attachment['url'].blank? || next_media_attachments.size > 4

      begin
        href = Addressable::URI.parse(attachment['url']).normalize.to_s

        media_attachment   = previous_media_attachments.find { |previous_media_attachment| previous_media_attachment.remote_url == href }
        media_attachment ||= MediaAttachment.new(account: @account, remote_url: href)

        media_attachment.description          = attachment['summary'].presence || attachment['name'].presence
        media_attachment.focus                = attachment['focalPoint']
        media_attachment.thumbnail_remote_url = icon_url_from_attachment(attachment)
        media_attachment.save!

        next_media_attachments << media_attachment

        next if unsupported_media_type?(attachment['mediaType']) || skip_download?

        RedownloadMediaWorker.perform_async(media_attachment.id) if media_attachment.remote_url_previously_changed? || media_attachment.thumbnail_remote_url_previously_changed?
      rescue Addressable::URI::InvalidURIError => e
        Rails.logger.debug "Invalid URL in attachment: #{e}"
      end
    end

    removed_media_attachments = previous_media_attachments - next_media_attachments

    MediaAttachment.where(id: removed_media_attachments.map(&:id)).update_all(status_id: nil)
    MediaAttachment.where(id: next_media_attachments.map(&:id)).update_all(status_id: @status.id)

    @media_attachments_changed = true if previous_media_attachments != @status.media_attachments.reload
  end

  def update_poll!
    previous_poll = @status.poll

    if equals_or_includes?(@json['type'], 'Question') && (@json['anyOf'].is_a?(Array) || @json['oneOf'].is_a?(Array))
      if @json['anyOf'].is_a?(Array)
        items = @json['anyOf']
        multiple = true
      else
        items = @json['oneOf']
        multiple = false
      end

      options = items.map { |item| item['name'].presence || item['content'] }.compact

      expires_at = begin
        if @json['closed'].is_a?(String)
          @json['closed']
        elsif !@json['closed'].nil? && !@json['closed'].is_a?(FalseClass)
          Time.now.utc
        else
          @json['endTime']
        end
      end

      voters_count = @json['votersCount']

      poll = begin
        if previous_poll&.options == options
          previous_poll
        else
          previous_poll&.destroy
          @account.polls.new(options: options, status: @status)
        end
      end

      poll.multiple       = multiple
      poll.expires_at     = expires_at
      poll.voters_count   = voters_count
      poll.cached_tallies = items.map { |item| item.dig('replies', 'totalItems') || 0 }
      poll.save!

      @status.poll = poll
    else
      previous_poll&.destroy
      @status.poll = nil
    end

    # Because of both has_one/belongs_to associations on status and poll,
    # poll_id is not updated on the status record here yet
    @media_attachments_changed = true if previous_poll&.id != @status.poll&.id
  end

  def update_immediate_attributes!
    @status.text         = text_from_content || ''
    @status.spoiler_text = text_from_summary || ''
    @status.sensitive    = @account.sensitized? || @json['sensitive'] || false
    @status.language     = language_from_content
    @status.edited_at    = @json['updated'] || Time.now.utc
    @status.save
  end

  def update_metadata!
    @raw_tags     = []
    @raw_mentions = []
    @raw_emojis   = []

    as_array(@json['tag']).each do |tag|
      if equals_or_includes?(tag['type'], 'Hashtag')
        @raw_tags << tag['name']
      elsif equals_or_includes?(tag['type'], 'Mention')
        @raw_mentions << tag['href']
      elsif equals_or_includes?(tag['type'], 'Emoji')
        @raw_emojis << tag
      end
    end

    update_tags!
    update_mentions!
    update_emojis!
  end

  def update_tags!
    @status.tags = Tag.find_or_create_by_names(@raw_tags)
  end

  def update_mentions!
    previous_mentions = @status.active_mentions.includes(:account).to_a
    current_mentions  = []

    @raw_mentions.each do |href|
      next if href.blank?

      account   = ActivityPub::TagManager.instance.uri_to_resource(href, Account)
      account ||= ActivityPub::FetchRemoteAccountService.new.call(href)

      next if account.nil?

      mention   = previous_mentions.find { |x| x.account_id == account.id }
      mention ||= account.mentions.new(status: @status)

      current_mentions << mention
    end

    current_mentions.each do |mention|
      mention.save if mention.new_record?
    end

    # If previous mentions are no longer contained in the text, convert them
    # to silent mentions, since withdrawing access from someone who already
    # received a notification might be more confusing
    removed_mentions = previous_mentions - current_mentions

    Mention.where(id: removed_mentions.map(&:id)).update_all(silent: true) unless removed_mentions.empty?
  end

  def update_emojis!
    return if skip_download?

    @raw_emojis.each do |raw_emoji|
      next if raw_emoji['name'].blank? || raw_emoji['icon'].blank? || raw_emoji['icon']['url'].blank?

      shortcode = raw_emoji['name'].delete(':')
      image_url = raw_emoji['icon']['url']
      uri       = raw_emoji['id']
      updated   = raw_emoji['updated']
      emoji     = CustomEmoji.find_by(shortcode: shortcode, domain: @account.domain)

      next unless emoji.nil? || image_url != emoji.image_remote_url || (updated && updated >= emoji.updated_at)

      begin
        emoji ||= CustomEmoji.new(domain: @account.domain, shortcode: shortcode, uri: uri)
        emoji.image_remote_url = image_url
        emoji.save
      rescue Seahorse::Client::NetworkingError => e
        Rails.logger.warn "Error storing emoji: #{e}"
      end
    end
  end

  def expected_type?
    equals_or_includes_any?(@json['type'], %w(Note Question))
  end

  def lock_options
    { redis: Redis.current, key: "create:#{@uri}", autorelease: 15.minutes.seconds }
  end

  def text_from_content
    if @json['content'].present?
      @json['content']
    elsif content_language_map?
      @json['contentMap'].values.first
    end
  end

  def content_language_map?
    @json['contentMap'].is_a?(Hash) && !@json['contentMap'].empty?
  end

  def text_from_summary
    if @json['summary'].present?
      @json['summary']
    elsif summary_language_map?
      @json['summaryMap'].values.first
    end
  end

  def summary_language_map?
    @json['summaryMap'].is_a?(Hash) && !@json['summaryMap'].empty?
  end

  def language_from_content
    if content_language_map?
      @json['contentMap'].keys.first
    elsif summary_language_map?
      @json['summaryMap'].keys.first
    else
      'und'
    end
  end

  def icon_url_from_attachment(attachment)
    url = begin
      if attachment['icon'].is_a?(Hash)
        attachment['icon']['url']
      else
        attachment['icon']
      end
    end

    return if url.blank?

    Addressable::URI.parse(url).normalize.to_s
  rescue Addressable::URI::InvalidURIError
    nil
  end

  def create_previous_edit!
    # We only need to create a previous edit when no previous edits exist, e.g.
    # when the status has never been edited. For other cases, we always create
    # an edit, so the step can be skipped

    return if @status.edits.any?

    @status.edits.create(
      text: @status.text,
      spoiler_text: @status.spoiler_text,
      media_attachments_changed: false,
      account_id: @account.id,
      created_at: @status.created_at
    )
  end

  def create_edit!
    @status_edit = @status.edits.create(
      text: @status.text,
      spoiler_text: @status.spoiler_text,
      media_attachments_changed: @media_attachments_changed,
      account_id: @account.id,
      created_at: @status.edited_at
    )
  end

  def skip_download?
    return @skip_download if defined?(@skip_download)

    @skip_download ||= DomainBlock.reject_media?(@account.domain)
  end

  def unsupported_media_type?(mime_type)
    mime_type.present? && !MediaAttachment.supported_mime_types.include?(mime_type)
  end

  def already_updated_more_recently?
    @status.edited_at.present? && @json['updated'].present? && @status.edited_at > @json['updated'].to_datetime
  rescue ArgumentError
    false
  end

  def reset_preview_card!
    @status.preview_cards.clear if @status.text_previously_changed? || @status.spoiler_text.present?
    LinkCrawlWorker.perform_in(rand(1..59).seconds, @status.id) if @status.spoiler_text.blank?
  end

  def broadcast_updates!
    ::DistributionWorker.perform_async(@status.id)
  end
end
