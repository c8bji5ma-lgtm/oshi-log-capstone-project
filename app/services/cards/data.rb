require "digest"
require "json"
require "vips"

module Cards
  class Data
    include DrawingPrimitives

    WIDTH = 1600
    HEIGHT = 1000
    BAR_COLOUR = [ 143, 101, 190 ].freeze
    PAPER = [ 253, 247, 255 ].freeze
    GRAPH = [ 248, 244, 253 ].freeze
    FUTURE = [ 235, 229, 241 ].freeze
    class InvalidSettings < StandardError; end
    class RenderingError < StandardError; end

    def self.settings(input)
      raise InvalidSettings unless input.is_a?(Hash) && input.keys.map(&:to_s).sort == %w[oshi_id year]
      input = input.stringify_keys
      year = input["year"]
      id = input["oshi_id"]
      raise InvalidSettings unless year.is_a?(String) && year.match?(/\A[0-9]{4}\z/) && year.to_i.positive?
      raise InvalidSettings unless id == "" || (id.is_a?(String) && id.match?(/\A[1-9][0-9]{0,18}\z/) && id.to_i <= 2**63 - 1)
      { year: year, oshi_id: id }
    end

    def initialize(user:, **input)
      settings = self.class.settings(input)
      @user = user
      @date = Date.current
      @year = settings[:year].to_i
      @profile = Profile.find_by(user_id: user.id) || raise(Photo::ProfileRequired)
      raise InvalidSettings unless OshiData::Summary.available_years(user: user, date: @date).include?(@year)
      @oshi = user.user_oshis.includes(:oshi).find_by!(oshi_id: settings[:oshi_id]).oshi if settings[:oshi_id].present?
      @summary = OshiData::Summary.new(user: user, date: @date, year: @year, oshi: @oshi)
    end

    # These records are for change detection, never an alternate aggregation.
    # Include all links of each included activity: another oshi's link changes
    # whether an expense is classified as sole-oshi or common.
    def fingerprint
      digest = Digest::SHA256.new
      digest.update(JSON.generate([ @date.iso8601, @year, @profile.id, @profile.display_name, @profile.updated_at.iso8601(6),
        (@oshi && [ @oshi.id, @oshi.name, @oshi.updated_at.iso8601(6) ]) ]))
      records = @user.activities.where(occurred_on: Date.new(@year, 1, 1)..@summary.period_end).where("occurred_on <= ?", @date)
      records = records.where(id: ActivityOshi.where(oshi_id: @oshi.id).select(:activity_id)) if @oshi
      records.select(:id, :occurred_on, :amount, :updated_at).preload(:activity_oshis).find_each do |activity|
        digest.update(JSON.generate([ activity.id, activity.occurred_on.iso8601, activity.amount, activity.updated_at.iso8601(6),
          activity.activity_oshis.sort_by(&:id).map { |link| [ link.id, link.oshi_id, link.updated_at.iso8601(6) ] } ]))
      end
      digest.hexdigest
    end

    # Summary owns every number. Missing future months are presentation state,
    # not zero-valued performance data.
    def statistics
      @statistics ||= begin
        actual = @summary.monthly_activities.index_by { |row| row[:month] }
        months = (1..12).map do |month|
          future = @year > @date.year || (@year == @date.year && month > @date.month)
          { month: month, count: future ? nil : actual.fetch(month).fetch(:count), future: future }
        end
        { count: @summary.activity_count, amount: @summary.activity_amount, recorded: @summary.amount_recorded?,
          months: months, period_end: @summary.period_end }
      end
    end

    def render
      raise Photo::FontUnavailable unless File.file?(Photo::FONT_FILE)
      stats = statistics
      canvas = solid_canvas(WIDTH, HEIGHT, PAPER)
      canvas = text(canvas, "推し活データ", x: 72, y: 64, width: 1020, size: 56, limit: 30)
      canvas = text(canvas, "#{@year}年", x: 1150, y: 72, width: 378, size: 32, limit: 10)
      canvas = text(canvas, @oshi&.name || "すべての推し", x: 1150, y: 116, width: 378, size: 26, limit: 24)
      period = "対象期間：#{Date.new(@year, 1, 1).strftime('%Y.%m.%d')}〜#{stats[:period_end].strftime('%Y.%m.%d')}"
      period += "（対象期間の実績はまだありません）" if @year > @date.year
      canvas = text(canvas, period, x: 72, y: 160, width: 1456, size: 26, limit: 80)
      canvas = panel(canvas, x: 72, label: "活動回数", value: "#{delimited(stats[:count])}回", colour: [ 252, 222, 237 ])
      amount = stats[:recorded] ? "#{delimited(stats[:amount])}円" : "支出記録なし"
      canvas = panel(canvas, x: 828, label: "活動支出", value: amount, colour: [ 223, 237, 254 ])
      canvas = graph(canvas, stats[:months])
      note = "活動支出に固定費は含みません。淡色の未来月は実績対象外です。"
      note = "複数推しの共通支出は含みません。" + note if @oshi
      canvas = text(canvas, note, x: 72, y: 884, width: 1456, size: 22, limit: 90)
      canvas = text(canvas, @profile.display_name, x: 1100, y: 930, width: 428, size: 26, minimum_size: 18, limit: 20)
      canvas = canvas.flatten(background: PAPER) if canvas.has_alpha?
      canvas.write_to_buffer(".png", compression: 6, strip: true)
    rescue Vips::Error, ArgumentError, KeyError
      raise RenderingError
    end

    private
      def delimited(number)
        ActiveSupport::NumberHelper.number_to_delimited(number)
      end

      def panel(canvas, x:, label:, value:, colour:)
        canvas = canvas.composite(solid_canvas(700, 170, colour), :over, x: x, y: 234)
        canvas = text(canvas, label, x: x + 24, y: 256, width: 652, size: 26, limit: 20)
        text(canvas, value, x: x + 24, y: 312, width: 652, size: 64, minimum_size: 28, limit: 64)
      end

      def graph(canvas, months)
        canvas = canvas.composite(solid_canvas(1456, 412, GRAPH), :over, x: 72, y: 436)
        canvas = text(canvas, "月別活動回数", x: 96, y: 452, width: 900, size: 24, limit: 30)
        maximum = months.filter_map { |month| month[:count] }.max || 0
        caption = @year > @date.year ? "実績はまだありません" : "活動記録がありません"
        canvas = text(canvas, caption, x: 960, y: 452, width: 544, size: 22, limit: 30) if maximum.zero?
        [ 0, maximum / 2, maximum ].uniq.each do |value|
          y = 780 - (maximum.zero? ? 0 : (value * 240.0 / maximum).round)
          canvas = canvas.composite(solid_canvas(1320, 1, [ 214, 204, 228 ]), :over, x: 144, y: y)
          canvas = text(canvas, delimited(value), x: 88, y: y - 12, width: 52, size: 20, minimum_size: 12, limit: 20)
        end
        future_months = months.select { |month| month[:future] }
        if future_months.any?
          # A continuous shaded region denotes unelapsed time, not tall bars.
          x = 154 + (future_months.first[:month] - 1) * 110
          canvas = canvas.composite(solid_canvas(future_months.length * 110 - 10, 320, FUTURE), :over, x: x, y: 520)
        end
        months.each_with_index do |row, index|
          x = 166 + index * 110
          if row[:future]
            canvas = text(canvas, "未来月", x: x - 10, y: 746, width: 90, size: 18, limit: 10)
          else
            height = maximum.zero? ? 0 : (row[:count] * 240.0 / maximum).round
            canvas = canvas.composite(solid_canvas(56, height, BAR_COLOUR), :over, x: x, y: 780 - height) if height.positive?
            canvas = text(canvas, delimited(row[:count]), x: x - 10, y: 748 - height, width: 90, size: 20, minimum_size: 12, limit: 20)
          end
          canvas = text(canvas, "#{row[:month]}月", x: x - 10, y: 806, width: 90, size: 22, limit: 10)
        end
        canvas
      end

      def text(canvas, value, x:, y:, width:, size:, limit:, minimum_size: size)
        value = value.gsub(/\r\n?/, "\n").tr("\n", " ")
        raise RenderingError unless value.valid_encoding? && !value.include?("\0")
        return canvas if value.match?(/\A[[:space:]]*\z/)
        clusters = value.each_grapheme_cluster.take(limit + 1)
        truncated = clusters.length > limit
        clusters = clusters.take(limit)
        size -= 1 while size > minimum_size && glyph_image(clusters.join + (truncated ? "…" : ""), size).width > width
        while clusters.any? && glyph_image(clusters.join + (truncated ? "…" : ""), size).width > width
          clusters.pop
          truncated = true
        end
        mask = glyph_image(clusters.join + (truncated ? "…" : ""), size)
        raise RenderingError if mask.width > width || mask.height > size * 1.4 || x + mask.width > WIDTH || y + mask.height > HEIGHT
        ink = text_ink(mask, [ 64, 42, 88 ])
        canvas.composite(ink, :over, x: x, y: y)
      end
  end
end
