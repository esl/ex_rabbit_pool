# `ex_rabbitmq_pool`

A RabbitMQ connection pooling library written in Elixir

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ex_rabbitmq_pool` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_rabbitmq_pool, "~> 0.1.0"}
  ]
end
```

* [![Coverage Status](https://coveralls.io/repos/github/esl/ex_rabbitmq_pool/badge.svg?branch=master)](https://coveralls.io/github/esl/ex_rabbitmq_pool?branch=master)
* [![Build Status](https://travis-ci.com/esl/ex_rabbitmq_pool.svg?branch=master)](https://travis-ci.com/esl/ex_rabbitmq_pool)
* [HexDocs](https://hexdocs.pm/ex_rabbitmq_pool)
* [Hex.pm](https://hex.pm/packages/ex_rabbitmq_pool)

## General Overview

- `ex_rabbitmq_pool` creates a pool of connections to RabbitMQ
- each connection worker traps exits and links the connection process to it
- each connection worker creates a pool of channels and links them to it
- when a client checks out a channel out of the pool the connection worker monitors that client to return the channel into it in case of a crash

## High Level Architecture


When starting a connection worker :

* We start a pool of multiplexed channels to RabbitMQ
* Store the channel pool to the connection workers state (we can move this later to ets).

Then:

* The connection worker traps exists of RabbitMQ channels - which means that :
    * If a channel crashes, the connection worker is going to be able to start another channel
    * If a connection to RabbitMQ crashes we are going to be able to restart that connection, remove all crashed channels and then restart them with a new connection;


Also:

* We are able to easily:
    * Monitor clients accessing channels,
    * Queue and dequeue channels from the pool in order to make them accessible to one client at a time reducing the potential for race conditions.

## Supervision hierarchy

![supervisor diagram](https://user-images.githubusercontent.com/1157892/52127565-681b8400-2600-11e9-8c37-34287e4c9b2c.png)

## Setting Up Queues on Start Up

Images are taken from [RabbitMQ Tutorials](https://www.rabbitmq.com/tutorials/tutorial-four-python.html)

### Basic config - Without Setting Any Queue

When you want to configure your self the queues on the right time for you, not on start up

```ex
# Rabbit Connection Configuration
rabbitmq_config = [
  channels: 1,
  port: "5672"
]

# Connection Pool Configuration
rabbitmq_conn_pool = [
  :rabbitmq_conn_pool,
  name: {:local, :rabbit_pool},
  worker_module: ExRabbitPool.Worker.RabbitConnection,
  size: 1,
  max_overflow: 0
]

ExRabbitPool.PoolSupervisor.start_link(
  rabbitmq_config: rabbitmq_config,
  rabbitmq_conn_pool: rabbitmq_conn_pool
)
```

### Setting up a direct exchange with bindings

![Direct Exchange Multiple](https://www.rabbitmq.com/img/tutorials/direct-exchange.png)

```ex
rabbitmq_config = [
  ..., # Basic Rabbit Connection Configuration
  queues: [
    [
      queue_name: "Q1",
      exchange: "X",
      queue_options: [],
      exchange_options: [],
      bind_options: [routing_key: "orange"]
    ],
    [
      queue_name: "Q2",
      exchange: "X",
      queue_options: [],
      exchange_options: [],
      bind_options: [routing_key: "black"]
    ],
    [
      queue_name: "Q2",
      exchange: "X",
      queue_options: [],
      exchange_options: [],
      bind_options: [routing_key: "green"]
    ]
  ]
]

# Basic Connection Pool Configuration
rabbitmq_conn_pool = [...]

ExRabbitPool.PoolSupervisor.start_link(
  rabbitmq_config: rabbitmq_config,
  rabbitmq_conn_pool: rabbitmq_conn_pool
)
```

### Setting up a direct exchange with multiple bindings

![Direct Exchange Multiple](https://www.rabbitmq.com/img/tutorials/direct-exchange-multiple.png)

```ex
rabbitmq_config = [
  ..., # Basic Rabbit Connection Configuration
  queues: [
    [
      queue_name: "Q1",
      exchange: "X",
      queue_options: [],
      exchange_options: [],
      bind_options: [routing_key: "black"]
    ],
    [
      queue_name: "Q2",
      exchange: "X",
      queue_options: [],
      exchange_options: [],
      bind_options: [routing_key: "black"]
    ]
  ]
]

# Basic Connection Pool Configuration
rabbitmq_conn_pool = [...]

ExRabbitPool.PoolSupervisor.start_link(
  rabbitmq_config: rabbitmq_config,
  rabbitmq_conn_pool: rabbitmq_conn_pool
)
```
