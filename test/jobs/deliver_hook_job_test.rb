require 'test_helper'

module Shipit
  class DeliverHookJobTest < ActiveSupport::TestCase
    setup do
      @delivery = shipit_deliveries(:scheduled_shipit_deploy)
      @job = DeliverHookJob.new
    end

    test "#perform delivers a delivery" do
      FakeWeb.register_uri(:post, @delivery.url, body: 'OK')
      @job.perform(@delivery)
      assert_equal 'sent', @delivery.reload.status
    end
  end
end
