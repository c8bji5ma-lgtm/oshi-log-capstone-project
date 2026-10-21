module Cards
  class RenderGate
    class Busy < StandardError; end

    @mutex = Mutex.new

    class << self
      def with
        raise Busy unless @mutex.try_lock

        begin
          yield
        ensure
          @mutex.unlock
        end
      end
    end
  end
end
