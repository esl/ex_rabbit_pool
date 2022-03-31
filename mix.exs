defmodule ExRabbitPool.MixProject do
  use Mix.Project

  @version "1.1.0"
  @url "https://github.com/esl/ex_rabbit_pool"

  def project do
    [
      app: :ex_rabbit_pool,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      description: "RabbitMQ connection pool library",
      package: package(),
      source_url: "https://github.com/esl/ex_rabbit_pool"
    ]
  end

  defp package() do
    [
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE),
      licenses: ["Apache 2"],
      links: %{
        "GitHub" => "https://github.com/esl/ex_rabbit_pool",
        "Blog Post" =>
          "https://www.erlang-solutions.com/blog/ex_rabbit_pool-open-source-amqp-connection-pool.html"
      }
    ]
  end

  def docs do
    [
      main: "README",
      source_url: @url,
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  def application do
    [
      # https://github.com/pma/amqp/issues/90
      extra_applications: [:logger, :amqp]
    ]
  end

  defp deps do
    [
      {:amqp, "~> 3.1"},
      {:poolboy, "~> 1.5"},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.20", only: :dev, runtime: false},
      {:excoveralls, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end
end
