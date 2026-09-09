#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open-uri"
require "openssl"
require "optparse"
require "rexml/document"
require "rss"
require "socket"
require "time"
require "timeout"

class OPMLFeedLoader
  def self.load(path)
    document = REXML::Document.new(File.read(path, encoding: "UTF-8"))
    root = document.root
    raise "document root must be opml" unless root&.name == "opml"
    raise "OPML version must be 2.0" unless root.attributes["version"] == "2.0"

    body = root.elements["body"]
    raise "OPML body is required" unless body

    feeds = []
    collect_feeds(body, feeds)
    raise "OPML must contain at least one feed" if feeds.empty?

    feeds
  rescue REXML::ParseException => e
    raise "invalid XML: #{e.message}"
  rescue SystemCallError, EncodingError => e
    raise e.message
  end

  def self.collect_feeds(parent, feeds)
    parent.each_element("outline") do |outline|
      xml_url = outline.attributes["xmlUrl"]
      unless xml_url.nil?
        text = outline.attributes["text"]
        raise "feed outline text must be a non-empty string" unless text.is_a?(String) && !text.strip.empty?
        raise "feed outline xmlUrl must be a non-empty string" if xml_url.strip.empty?

        feeds << { name: text, url: xml_url }
      end

      collect_feeds(outline, feeds)
    end
  end
  private_class_method :collect_feeds
end

class RSSFetch
  class FeedError < StandardError
  end
  class FetchError < StandardError
  end

  Result =
    Struct.new(:feeds, :errors, keyword_init: true) do
      def errors?
        !errors.empty?
      end
    end

  class HTTPFeedFetcher
    def fetch(url)
      URI.open(url, open_timeout: FETCH_TIMEOUT_SECONDS, read_timeout: FETCH_TIMEOUT_SECONDS).read
    rescue OpenURI::HTTPError,
           URI::Error,
           SocketError,
           Timeout::Error,
           OpenSSL::SSL::SSLError,
           SystemCallError,
           IOError => e
      raise FetchError, "fetch error: #{e.message}"
    end
  end

  ATOM_FALLBACK_TIME = Time.at(0).getutc.freeze
  SUMMARY_MAX_LENGTH = 1_000
  FETCH_TIMEOUT_SECONDS = 10

  def initialize(feeds:, feed_fetcher: HTTPFeedFetcher.new)
    validate_feeds(feeds)
    validate_feed_fetcher(feed_fetcher)

    @feeds = feeds
    @feed_fetcher = feed_fetcher
  end

  def collect_feeds(item_limit: nil, max_age_days: nil, now: nil, progress: true)
    validate_item_limit(item_limit)
    validate_max_age_days(max_age_days)

    result = Result.new(feeds: [], errors: [])
    now = (now || Time.now).getutc

    @feeds.each do |feed|
      warn "Fetching: #{feed[:name]}" if progress

      begin
        data = fetch_feed(feed[:url])
        items = parse_feed(data)
        items = filter_recent_items(items, max_age_days, now) unless max_age_days.nil?
        items = items.first(item_limit) unless item_limit.nil?
        result.feeds << feed.merge(items: items)
      rescue FeedError, FetchError => e
        result.errors << feed.merge(error: e.message)
      end
    end

    result
  end

  private

  def validate_feeds(feeds)
    raise ArgumentError, "feeds must be a non-empty array" unless feeds.is_a?(Array) && !feeds.empty?

    feeds.each_with_index do |feed, index|
      raise ArgumentError, "feeds[#{index}] must be an object" unless feed.is_a?(Hash)

      unless feed[:name].is_a?(String) && !feed[:name].strip.empty?
        raise ArgumentError, "feeds[#{index}].name must be a non-empty string"
      end

      unless feed[:url].is_a?(String) && !feed[:url].strip.empty?
        raise ArgumentError, "feeds[#{index}].url must be a non-empty string"
      end
    end
  end

  def validate_item_limit(item_limit)
    return if item_limit.nil? || (item_limit.is_a?(Integer) && item_limit.positive?)

    raise ArgumentError, "item_limit must be a positive integer"
  end

  def validate_max_age_days(max_age_days)
    return if max_age_days.nil? || (max_age_days.is_a?(Integer) && max_age_days >= 0)

    raise ArgumentError, "max_age_days must be a non-negative integer"
  end

  def validate_feed_fetcher(feed_fetcher)
    return if feed_fetcher.respond_to?(:fetch)

    raise ArgumentError, "feed_fetcher must respond to fetch"
  end

  def fetch_feed(url)
    @feed_fetcher.fetch(url)
  end

  def parse_feed(data)
    feed = RSS::Parser.parse(data, false)
    raise FeedError, "unsupported feed format (expected RSS or Atom)" unless feed&.respond_to?(:to_feed)

    atom_feed = feed.is_a?(RSS::Atom::Feed) ? feed : convert_to_atom(feed)
    parse_atom(atom_feed).reject { |item| item[:published].empty? }
  rescue RSS::Error => e
    raise FeedError, "invalid XML: #{e.message}"
  end

  def convert_to_atom(feed)
    feed.items.select! { |item| item.date }

    feed.to_feed("atom") do |maker|
      maker.channel.id ||= maker.channel.link
      maker.channel.updated ||= maker.channel.lastBuildDate || ATOM_FALLBACK_TIME
      maker.channel.author ||= maker.channel.title
      maker.channel.categories.clear
      maker.items.each do |item|
        item.id ||= item.guid || item.link
        item.updated ||= item.published
        item.summary ||= item.content_encoded
        item.categories.clear
      end
    end
  end

  def parse_atom(feed)
    feed.items.each.map do |entry|
      summary = atom_text(entry.summary)
      summary = atom_text(entry.content) if summary.nil?

      normalized_item(
        title: atom_text(entry.title),
        link: atom_link(entry),
        published: atom_time(entry.published) || atom_time(entry.updated),
        summary: summary
      )
    end
  end

  def atom_text(element)
    return nil unless element

    element.content.to_s.strip
  end

  def atom_time(element)
    element && element.content
  end

  def atom_link(entry)
    links = entry.links
    alternate = links.find { |link| (link.rel.nil? || link.rel == "alternate") && present?(link.href) }
    selected = alternate || links.find { |link| present?(link.href) }
    selected ? selected.href.strip : ""
  end

  def normalized_item(title:, link:, published:, summary:)
    {
      title: text(title),
      link: text(link),
      published: normalize_published(published),
      # summary: text(summary).slice(0, SUMMARY_MAX_LENGTH)
    }
  end

  def text(value)
    value.nil? ? "" : value.to_s.strip
  end

  def normalize_published(value)
    published = parse_published(value)
    published ? published.getutc.iso8601.sub(/Z\z/, "+00:00") : ""
  end

  def parse_published(value)
    return value.to_time if value.respond_to?(:to_time)
    return nil if value.nil? || value.to_s.empty?

    Time.rfc2822(value.to_s)
  rescue ArgumentError
    begin
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end

  def filter_recent_items(items, max_age_days, now)
    cutoff = now.getutc - (max_age_days * 86_400)
    items.select do |item|
      published = parse_published(item[:published])
      published && published >= cutoff
    end
  end

  def present?(value)
    value && !value.strip.empty?
  end
end

if __FILE__ == $0
  runtime_options = { item_limit: nil, max_age_days: nil }
  parser =
    OptionParser.new do |options|
      options.banner = "Usage: rss_fetch.rb [--item-limit INTEGER] [--max-age-days INTEGER] CONFIG_PATH"
      options.separator("Fetch RSS 1.0, RSS 2.0, and Atom feeds configured in OPML 2.0.")
      options.on("--item-limit INTEGER", Integer, "Maximum number of articles per feed (positive integer)") do |value|
        raise OptionParser::InvalidArgument, "--item-limit must be a positive integer" unless value.positive?
        runtime_options[:item_limit] = value
      end
      options.on("--max-age-days INTEGER", Integer, "Maximum article age in days (non-negative integer)") do |value|
        raise OptionParser::InvalidArgument, "--max-age-days must be a non-negative integer" if value.negative?
        runtime_options[:max_age_days] = value
      end
      options.on("-h", "--help", "Show this help") do
        puts options
        exit 0
      end
    end

  arguments = ARGV.dup
  begin
    parser.parse!(arguments)
    raise OptionParser::MissingArgument, "CONFIG_PATH" unless arguments.length == 1
  rescue OptionParser::ParseError => e
    warn "Argument error: #{e.message}"
    warn parser
    exit 2
  end

  config_path = arguments.first
  begin
    feeds = OPMLFeedLoader.load(config_path)
    rss_fetch = RSSFetch.new(feeds: feeds)
  rescue RuntimeError, ArgumentError => e
    warn "Configuration error: #{e.message}"
    exit 2
  end

  item_limit_label = runtime_options[:item_limit] || "unlimited"
  max_age_days_label = runtime_options[:max_age_days] || "unlimited"
  warn(
    "Start: config=#{config_path} feeds=#{feeds.length} item_limit=#{item_limit_label} max_age_days=#{max_age_days_label}"
  )
  result = rss_fetch.collect_feeds(**runtime_options)
  article_count = result.feeds.sum { |feed| feed[:items].length }
  warn "Complete: articles=#{article_count}"
  puts JSON.pretty_generate(result.to_h)
  exit result.errors? ? 1 : 0
end
