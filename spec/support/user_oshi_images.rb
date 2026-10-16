require "tempfile"

module UserOshiImages
  def library_upload(filename = "image.png", size: nil)
    bytes = File.binread(Rails.root.join("spec/fixtures/files", filename))
    file = Tempfile.new([ "oshi-image-", File.extname(filename) ])
    file.binmode
    file.write(size ? bytes.ljust(size, "\0") : bytes)
    file.rewind
    type = { ".jpg" => "image/jpeg", ".png" => "image/png", ".webp" => "image/webp" }.fetch(File.extname(filename), "text/plain")
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: type)
  end
end
