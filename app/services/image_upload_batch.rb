class ImageUploadBatch
  MAX_TOTAL_BYTE_SIZE = 10.megabytes

  def self.too_large?(files)
    Array(files).compact_blank.sum { |file| byte_size(file) } > MAX_TOTAL_BYTE_SIZE
  end

  def self.byte_size(file)
    io = file[:io] if file.respond_to?(:[])
    return file.size if io.nil? && file.respond_to?(:size)
    return 0 unless io

    return io.size if io.respond_to?(:size)

    current = io.pos if io.respond_to?(:pos)
    io.seek(0, IO::SEEK_END)
    size = io.pos
    io.seek(current, IO::SEEK_SET) if current
    size
  rescue IOError, SystemCallError
    0
  end

  private_class_method :byte_size
end
