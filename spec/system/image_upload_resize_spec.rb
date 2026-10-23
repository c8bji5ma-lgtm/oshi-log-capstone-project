require "rails_helper"
require "tmpdir"
require "digest"

RSpec.describe "Client image resizing", type: :system do
  let(:user) { create(:user) }

  around do |example|
    Dir.mktmpdir("oshilog-client-image-") do |directory|
      @image_directory = Pathname.new(directory)
      example.run
    end
  end

  def sign_in
    visit new_user_session_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(root_path)
  end

  def patterned_image(width, height)
    xy = Vips::Image.xyz(width, height)
    r = ((xy[0] * 17 + xy[1] * 31) % 256).cast(:uchar)
    g = ((xy[0] * 7 + xy[1] * 13) % 256).cast(:uchar)
    b = ((((xy[0] / 32).floor + (xy[1] / 24).floor) % 2) * 127 + 64).cast(:uchar)
    r.bandjoin([ g, b ]).copy(interpretation: :srgb)
  end

  def jpeg_file(name, width: 3000, height: 2000, orientation: nil)
    path = @image_directory.join(name)
    image = patterned_image(width, height)
    if orientation
      image = image.copy
      image.set_type(GObject::GINT_TYPE, "orientation", orientation)
    end
    image.write_to_file(path.to_s, Q: 95, strip: orientation.nil?)
    path
  end

  def transparent_png(name, width: 3000, height: 2000)
    path = @image_directory.join(name)
    image = patterned_image(width, height).bandjoin(Vips::Image.black(width, height).new_from_image(64))
    image.write_to_file(path.to_s, compression: 6, strip: true)
    path
  end

  def selected_file_info(label, alpha: false)
    input = find_field(label)
    page.evaluate_async_script(<<~JS, input, alpha)
      const input = arguments[0], inspectAlpha = arguments[1], done = arguments[2];
      const file = input.files[0];
      if (!file) return done({error: "missing"});
      createImageBitmap(file, {imageOrientation: "from-image"}).then(bitmap => {
        let alphaValue = null;
        if (inspectAlpha) {
          const canvas = document.createElement("canvas");
          canvas.width = bitmap.width;
          canvas.height = bitmap.height;
          const context = canvas.getContext("2d", {alpha: true});
          context.drawImage(bitmap, 0, 0);
          alphaValue = context.getImageData(0, 0, 1, 1).data[3];
          canvas.width = 1;
          canvas.height = 1;
        }
        const result = {name: file.name, type: file.type, size: file.size,
          width: bitmap.width, height: bitmap.height, alpha: alphaValue};
        bitmap.close();
        done(result);
      }).catch(error => done({error: error.name}));
    JS
  end

  it "attaches the shared processor to all four upload entry points" do
    personal = create(:user_oshi, user: user, oshi: create(:oshi, :approved))
    sign_in

    visit edit_profile_path
    expect(page).to have_css("[data-controller~='image-upload'] input[name='profile[profile_image]']", count: 1)

    visit edit_user_oshi_path(personal)
    expect(page).to have_css("[data-controller~='image-upload'] input[type='file']", count: 2)

    visit new_activity_path
    expect(page).to have_css("[data-controller~='image-upload'] input[name='activity[images][]']", count: 1)

    visit new_oshi_path
    expect(page).to have_css("[data-controller~='image-upload'] input[name='user_oshi[library_images][]']", count: 1)
  end

  it "keeps a compliant file unchanged and resizes a large JPEG copy before saving" do
    large = jpeg_file("large.jpg")
    original_digest = Digest::SHA256.file(large).hexdigest
    fixture = Rails.root.join("spec/fixtures/files/image.jpg")
    sign_in
    visit edit_profile_path

    attach_file "プロフィール画像", fixture
    expect(page).to have_css("#profile-image-status", text: "元のファイルを使用します", wait: 10)
    unchanged = selected_file_info("プロフィール画像")
    expect(unchanged).to include("name" => "image.jpg", "size" => File.size(fixture), "type" => "image/jpeg")

    attach_file "プロフィール画像", large
    expect(page).to have_button("プロフィールを保存", disabled: true)
    expect(page).to have_css("#profile-image-status", text: "1枚を縮小しました", wait: 20)
    resized = selected_file_info("プロフィール画像")
    expect(resized["type"]).to eq("image/jpeg")
    expect(resized["width"]).to be <= 2560
    expect(resized["height"]).to be <= 2560
    expect(resized["width"] * resized["height"]).to be <= 5_000_000
    expect(resized["size"]).to be <= 10.megabytes
    expect(Digest::SHA256.file(large).hexdigest).to eq(original_digest)

    fill_in "表示名（必須）", with: "縮小確認"
    click_button "プロフィールを保存"
    expect(page).to have_css("[role='status']", text: "プロフィールを更新しました。")
    bytes = user.reload.profile.profile_image.download
    saved = Vips::Image.new_from_buffer(bytes, "", access: :sequential)
    expect(saved.width).to eq(resized["width"])
    expect(saved.height).to eq(resized["height"])
    expect(saved.deviate).to be > 10
  end

  it "normalizes EXIF orientation once and preserves PNG transparency" do
    oriented = jpeg_file("oriented.jpg", orientation: 6)
    alpha = transparent_png("transparent.png")
    sign_in
    visit edit_profile_path

    attach_file "プロフィール画像", oriented
    expect(page).to have_css("#profile-image-status", text: "1枚を縮小しました", wait: 20)
    oriented_info = selected_file_info("プロフィール画像")
    expect(oriented_info["width"]).to be < oriented_info["height"]
    expect(oriented_info["height"]).to eq(2560)
    expect(oriented_info["width"] * oriented_info["height"]).to be <= 5_000_000

    attach_file "プロフィール画像", alpha
    expect(page).to have_css("#profile-image-status", text: "1枚を縮小しました", wait: 20)
    alpha_info = selected_file_info("プロフィール画像", alpha: true)
    expect(alpha_info["type"]).to eq("image/png")
    expect(alpha_info["alpha"]).to be_between(1, 254)
    expect(alpha_info["size"]).to be <= 10.megabytes
  end

  it "clears the whole batch on failure and ignores an older asynchronous selection" do
    personal = create(:user_oshi, user: user, oshi: create(:oshi, :approved))
    large = jpeg_file("first.jpg")
    invalid = @image_directory.join("invalid.txt")
    File.write(invalid, "not an image")
    fixture = Rails.root.join("spec/fixtures/files/image.jpg")
    sign_in
    visit edit_user_oshi_path(personal)

    attach_file "追加画像", [ large, invalid ]
    expect(page).to have_css("#library-image-help-status[role='alert']", text: "JPEG・PNG・WebP", wait: 20)
    input = find_field("追加画像")
    expect(page.evaluate_script("arguments[0].files.length", input)).to eq(0)
    expect(personal.reload.library_images).not_to be_attached

    page.execute_script(<<~JS)
      window.originalCreateImageBitmap = window.createImageBitmap;
      let delayed = true;
      window.createImageBitmap = (...args) => {
        const wait = delayed ? 500 : 0;
        delayed = false;
        return new Promise((resolve, reject) => setTimeout(() => {
          window.originalCreateImageBitmap(...args).then(resolve, reject);
        }, wait));
      };
    JS
    attach_file "追加画像", large
    expect(page).to have_button("画像を追加", disabled: true)
    attach_file "追加画像", fixture
    expect(page).to have_css("#library-image-help-status", text: "元のファイルを使用します", wait: 20)
    expect(selected_file_info("追加画像")["name"]).to eq("image.jpg")
    expect(page).to have_button("画像を追加", disabled: false)
  ensure
    page.execute_script("if (window.originalCreateImageBitmap) window.createImageBitmap = window.originalCreateImageBitmap") if page.current_url
  end
end
