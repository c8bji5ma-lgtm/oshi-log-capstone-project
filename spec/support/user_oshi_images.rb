require "tempfile"

module UserOshiImages
  def library_upload_data(bytes, filename: "image.png", type: "image/png")
    file = Tempfile.new([ "oshi-image-", File.extname(filename) ])
    file.binmode
    file.write(bytes)
    file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: type)
  end

  def library_upload(filename = "image.png", size: nil)
    bytes = File.binread(Rails.root.join("spec/fixtures/files", filename))
    type = { ".jpg" => "image/jpeg", ".png" => "image/png", ".webp" => "image/webp" }.fetch(File.extname(filename), "text/plain")
    library_upload_data(size ? bytes.ljust(size, "\0") : bytes, filename: filename, type: type)
  end
end
