import Config

# Production configuration loaded at runtime
if config_env() == :prod do
  config :logger,
    level: :info,
    compile_time_purge_matching: [[level_lower_than: :info]]
  
  # Disable console colors in production
  config :logger, :console,
    format: "$time $metadata[$level] $message\n",
    metadata: [:request_id, :user_id],
    colors: [enabled: false]
end
