require "rails_helper"

RSpec.describe RateLimitChecker, type: :service do
  let(:user) { create(:user) }
  let(:article) { create(:article, user: user) }
  let(:rate_limit_checker) { described_class.new(user) }

  def cache_key(action)
    rate_limit_checker.send("limit_cache_key", action)
  end

  describe "#limit_by_action" do
    it "returns false for invalid action" do
      expect(rate_limit_checker.limit_by_action("random-nothing")).to be(false)
    end

    # published_article_creation limit we check against the database rather than our cache
    RateLimitChecker::ACTION_LIMITERS.except(:published_article_creation).each do |action, _options|
      it "returns true if #{action} limit has been reached" do
        allow(Rails.cache).to receive(:read).with(
          cache_key(action),
        ).and_return(SiteConfig.public_send("rate_limit_#{action}") + 1)

        expect(rate_limit_checker.limit_by_action(action)).to be(true)
      end

      it "returns false if #{action} limit has NOT been reached" do
        allow(Rails.cache).to receive(:read).with(
          cache_key(action),
        ).and_return(SiteConfig.public_send("rate_limit_#{action}"))

        expect(rate_limit_checker.limit_by_action(action)).to be(false)
      end
    end

    context "when creating comments" do
      before do
        allow(SiteConfig).to receive(:rate_limit_comment_creation).and_return(1)
      end

      it "returns true if too many comments at once" do
        create_list(:comment, 2, user_id: user.id, commentable: article)
        expect(rate_limit_checker.limit_by_action("comment_creation")).to be(true)
      end

      it "returns false if allowed comment" do
        expect(rate_limit_checker.limit_by_action("comment_creation")).to be(false)
      end
    end

    it "returns true if too many published articles at once" do
      allow(SiteConfig).to receive(:rate_limit_published_article_creation).and_return(1)
      create_list(:article, 2, user_id: user.id, published: true)
      expect(rate_limit_checker.limit_by_action("published_article_creation")).to be(true)
    end

    it "returns true if a user has followed more than <daily_limit> accounts today" do
      allow(rate_limit_checker).
        to receive(:user_today_follow_count).
        and_return(SiteConfig.rate_limit_follow_count_daily + 1)

      expect(rate_limit_checker.limit_by_action("follow_account")).to be(true)
    end

    it "returns false if a user's following_users_count is less than <daily_limit>" do
      allow(user).
        to receive(:following_users_count).
        and_return(SiteConfig.rate_limit_follow_count_daily - 1)

      expect(rate_limit_checker.limit_by_action("follow_account")).to be(false)
    end

    it "returns false if a user has followed less than <daily_limit> accounts today" do
      allow(rate_limit_checker).
        to receive(:user_today_follow_count).
        and_return(SiteConfig.rate_limit_follow_count_daily)

      expect(rate_limit_checker.limit_by_action("follow_account")).to be(false)
    end

    it "returns false if published articles limit has not been reached" do
      expect(described_class.new(user).limit_by_action("published_article_creation")).to be(false)
    end

    it "logs a rate limit hit to datadog" do
      allow(Rails.cache).
        to receive(:read).with("#{user.id}_organization_creation").
        and_return(SiteConfig.rate_limit_organization_creation + 1)
      allow(DatadogStatsClient).to receive(:increment)
      described_class.new(user).limit_by_action("organization_creation")

      expect(DatadogStatsClient).to have_received(:increment).with(
        "rate_limit.limit_reached",
        tags: ["user:#{user.id}", "action:organization_creation"],
      )
    end
  end

  describe "#check_limit!" do
    it "returns nil if limit_by_action is false" do
      allow(rate_limit_checker).to receive(:limit_by_action).and_return(false)
      expect(rate_limit_checker.check_limit!(:image_upload)).to be_nil
    end

    it "raises an error if limit_by_action is true" do
      allow(rate_limit_checker).to receive(:limit_by_action).and_return(true)
      expect { rate_limit_checker.check_limit!(:image_upload) }.to raise_error(described_class::LimitReached)
    end
  end

  describe "#track_limit_by_action" do
    it "increments cache for action with retry as expiration" do
      allow(Rails.cache).to receive(:increment)
      action = :image_upload
      rate_limit_checker.track_limit_by_action(action)

      key = "#{user.id}_#{action}"
      expires_in = described_class::ACTION_LIMITERS.dig(action, :retry_after)
      expect(Rails.cache).to have_received(:increment).with(key, 1, expires_in: expires_in)
    end
  end

  describe "#limit_by_email_recipient_address" do
    before do
      allow(SiteConfig).to receive(:rate_limit_email_recipient).and_return(1)
    end

    it "returns true if too many emails are sent to the same recipient" do
      2.times { EmailMessage.create(to: user.email, sent_at: Time.current) }
      expect(described_class.new.limit_by_email_recipient_address(user.email)).to be(true)
    end

    it "returns false if we are below the message limit for this recipient" do
      expect(described_class.new.limit_by_email_recipient_address(user.email)).to be(false)
    end
  end
end
