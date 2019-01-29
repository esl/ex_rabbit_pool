use Mix.Config

config :logger, handle_otp_reports: true, handle_sasl_reports: true
config :sasl, :sasl_error_logger, false
# https://github.com/pma/amqp/issues/90
# https://github.com/PSPDFKit-labs/lager_logger/blob/master/config/config.exs
# Stop lager redirecting :error_logger messages
config :lager, :error_logger_redirect, false

# Stop lager removing Logger's :error_logger handler
config :lager, :error_logger_whitelist, [Logger.ErrorHandler]

# Stop lager writing a crash log
config :lager, :crash_log, false

# Use LagerLogger as lager's only handler.
config :lager, :handlers, [{LagerLogger, [level: :debug]}]

# https://github.com/pma/amqp/wiki/Upgrade-from-0.X-to-1.0#lager
config :lager, handlers: [level: :critical]
