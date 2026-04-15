# frozen_string_literal: true

RSpec.describe Turbocable do
  it "has a version string" do
    expect(Turbocable::VERSION).to be_a(String)
  end

  it "uses semantic versioning" do
    expect(Turbocable::VERSION).to match(/\A\d+\.\d+\.\d+(?:[.-]\w+)?\z/)
  end
end
