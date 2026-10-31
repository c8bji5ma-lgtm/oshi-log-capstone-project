require "rails_helper"
require "vips"
require_relative "../support/card_images"

RSpec.describe "Reading a personal oshi list", type: :system do
  include CardImages

  let(:user) { create(:user) }

  def login
    visit new_user_session_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_css("main h1", text: "ホーム", exact_text: true)
  end

  def expect_oshi_list
    expect(page).to have_current_path(oshis_path)
    expect(page).to have_css("main h1", text: "推し一覧", exact_text: true)
    expect(page).to have_no_css("html[data-turbo-preview], html[aria-busy='true']")
  end

  def layout
    page.evaluate_script(<<~JS)
      (() => {
        const rect = e => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height, right: r.right, bottom: r.bottom }; };
        return {
          overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
          cards: [...document.querySelectorAll(".oshi-list-card")].map(card => {
            const heading = card.querySelector("h2"), image = card.querySelector("img"), info = card.querySelector(".oshi-list-info");
            const style = getComputedStyle(card);
            return {
              name: heading.textContent, heading: rect(heading), image: rect(image), info: rect(info),
              contentWidth: card.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
              headingUncut: heading.scrollWidth <= heading.clientWidth && heading.scrollHeight <= heading.clientHeight + 1,
              loaded: image.complete && image.naturalWidth > 0, fit: getComputedStyle(image).objectFit,
              alt: image.alt, links: [...card.querySelectorAll("a")].map(a => ({ text: a.textContent, href: a.getAttribute("href"), label: a.getAttribute("aria-label"), height: a.getBoundingClientRect().height }))
            };
          })
        };
      })()
    JS
  end

  [ 375, 1280 ].each do |width|
    it "shows complete names, whole personal images and distinct actions at #{width}px" do
      records = [
        create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "星空をつなぐ推し")),
        create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: "思い出の推し" * 32 + "A" * 63)),
        create(:user_oshi, user: user, oshi: create(:oshi, :pending, created_by_user: user)),
        create(:user_oshi, user: user, oshi: create(:oshi, :rejected))
      ]
      [ [ 240, 360 ], [ 360, 180 ], [ 240, 240 ] ].each_with_index do |(w, h), index|
        attach_coordinates(records[index], width: w, height: h)
      end
      foreign = create(:user_oshi, oshi: records.first.oshi)
      attach_coordinates(foreign, width: 360, height: 180)
      private_oshi = create(:oshi, :pending, created_by_user: foreign.user, name: "他人の非公開推し")
      create(:user_oshi, user: foreign.user, oshi: private_oshi)
      page.current_window.resize_to(width, 900)
      login
      visit oshis_path

      expect_oshi_list
      expect(page).to have_css(".oshi-list-card", count: records.size)
      expect(page).to have_no_text(private_oshi.name)
      expect(page).to have_no_css("img[src='#{protected_image_path(foreign.representative_image.attachment)}']")
      data = layout
      expect(data["overflow"]).to be(false)
      expect(data["cards"].map { |card| card["name"] }).to eq(records.map { |record| record.oshi.name })
      data["cards"].zip(records).each do |card, record|
        expect(card["headingUncut"]).to be(true)
        expect(card["heading"]["width"]).to be_within(1).of(card["contentWidth"])
        expect(card["image"]["y"]).to be >= card["heading"]["bottom"]
        expect(card["image"].slice("width", "height")).to eq("width" => 120, "height" => 120)
        expect(card["loaded"]).to be(true)
        expect(card["fit"]).to eq("contain")
        expect(card["alt"]).to eq("#{record.oshi.name}の代表画像")
        expect(card["image"]["right"]).to be <= card["info"]["x"]
        expect(card["links"].map { |link| link["href"] }).to eq([ user_oshi_path(record), edit_user_oshi_path(record) ])
        expect(card["links"].map { |link| link["label"] }).to eq([ "#{record.oshi.name}の詳細", "#{record.oshi.name}を編集" ])
        expect(card["links"].all? { |link| link["height"] >= 44 }).to be(true)
      end
      expect(page).to have_link("活動記録一覧", href: activities_path)
      within(first(".oshi-list-card")) { click_link "詳細", exact: true }
      expect(page).to have_current_path(user_oshi_path(records.first))
      expect(page).to have_no_css("html[data-turbo-preview], html[aria-busy='true']")
      click_link "推し一覧", exact: true
      expect_oshi_list
      within(first(".oshi-list-card")) { click_link "編集", exact: true }
      expect(page).to have_current_path(edit_user_oshi_path(records.first))
      expect(page).to have_no_css("html[data-turbo-preview], html[aria-busy='true']")
    ensure
      page.current_window.resize_to(1280, 1024)
    end
  end

  it "keeps long names and keyboard actions reachable at 320px and enlarged text" do
    name = "長い日本語の名前を省略せずに残す" * 7
    record = create(:user_oshi, user: user, oshi: create(:oshi, :approved, name: name))
    attach_coordinates(record, width: 240, height: 360)
    login
    [ [ 320, "100%" ], [ 375, "200%" ] ].each do |width, scale|
      page.current_window.resize_to(width, 900)
      visit oshis_path
      expect_oshi_list
      page.execute_script("document.documentElement.style.fontSize = arguments[0]", scale)
      data = layout
      expect(data["overflow"]).to be(false)
      card = data["cards"].first
      expect(card["name"]).to eq(name)
      expect(card["headingUncut"]).to be(true)
      expect(card["heading"]["width"]).to be_within(1).of(card["contentWidth"])
      expect(card["info"]["y"]).to be >= card["image"]["bottom"]
      expect(card["image"].slice("width", "height")).to eq("width" => 120, "height" => 120)

      find_link("推しを登録", exact: true).send_keys(:tab)
      expect(page).to have_css(".oshi-list-card a:focus[href='#{user_oshi_path(record)}']")
      find("a[href='#{user_oshi_path(record)}']").send_keys(:tab)
      expect(page).to have_css(".oshi-list-card a:focus[href='#{edit_user_oshi_path(record)}']")
      focus = page.evaluate_script("({width: parseFloat(getComputedStyle(document.activeElement).outlineWidth), style: getComputedStyle(document.activeElement).outlineStyle})")
      expect(focus["width"]).to be >= 3
      expect(focus["style"]).to eq("solid")
      page.execute_script("document.documentElement.style.fontSize = ''")
    end
  ensure
    page.execute_script("document.documentElement.style.fontSize = ''")
    page.current_window.resize_to(1280, 1024)
  end

  it "keeps the first registration action clear when the personal list is empty" do
    login
    visit oshis_path
    expect_oshi_list
    expect(page).to have_text("登録している推しはありません。")
    expect(page).to have_no_css(".oshi-list-card")
    expect(page).to have_link("推しを登録", href: new_oshi_path, count: 1)
    expect(page).to have_link("活動記録一覧", href: activities_path)
    click_link "推しを登録", exact: true
    expect(page).to have_current_path(new_oshi_path)
  end
end
