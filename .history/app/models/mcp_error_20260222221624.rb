class McpError < StandardError
  attr_reader :code, :data

  def initialize(code, message, data = nil)
    super(message)
    @code = code
    @data = data
  end
end
