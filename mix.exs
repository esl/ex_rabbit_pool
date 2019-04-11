defmodule BugsBunny.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_rabbit_pool,
      version: "1.0.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      organization: "esl",
      description: "RabbitMQ connection pool library",
      package: package(),
      source_url: "https://github.com/esl/ex_rabbit_pool"
    ]
  end

  defp package() do
    [
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["Apache 2"],
      links: %{"GitHub" => "https://github.com/esl/ex_rabbit_pool"}
    ]
  end

  def application do
    [
      # https://github.com/pma/amqp/issues/90
      extra_applications: [:lager, :logger, :amqp]
    ]
  end

  defp deps do
    [
      {:amqp, "~> 1.1"},
      # amqp and tentacat depends on jsx
      {:jsx, "2.8.2", override: true},
      # https://github.com/pma/amqp/issues/99
      {:ranch, "1.5.0", override: true},
      # https://github.com/pma/amqp/issues/99
      {:ranch_proxy_protocol, "~> 2.0", override: true},
      {:poolboy, "~> 1.5"},
      {:credo, "~> 1.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.18", only: :dev, runtime: false},
      {:excoveralls, "~> 0.10.4", only: [:dev, :test], runtime: false}
    ]
  end
end
