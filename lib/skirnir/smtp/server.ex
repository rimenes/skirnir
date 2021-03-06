defmodule Skirnir.Smtp.Server do
  require Logger

  use GenStateMachine
  import Skirnir.Smtp.Server.Parser, only: [parse: 1]
  import Skirnir.Smtp.ErrorCodes, only: [error: 1, error: 2, error: 3]
  import Skirnir.Inet, only: [gethostinfo: 1]

  alias Skirnir.Smtp.Server.Storage
  alias Skirnir.Smtp.Server.Queue
  alias Skirnir.Smtp.Email
  alias Skirnir.Tls
  alias :ranch, as: Ranch
  alias :ranch_ssl, as: RanchSsl

  @behaviour :ranch_protocol
  @timeout 5000
  @tries 2

  defmodule StateData do
    defstruct id: nil,
              # connection
              socket: nil,
              tcp_socket: nil,
              transport: nil,
              # info for connection
              address: nil,
              remote_name: nil,
              tls: false,
              # closures
              send: nil,
              # config
              domains: [],
              hostname: nil,
              tries: 0,
              # sent by client
              host: nil,
              from: nil,
              recipients: [],
              data: ""
  end

  def start_link(ref, socket, transport, _opts) do
    GenStateMachine.start_link(__MODULE__, [ref, socket, transport])
  end

  def init([ref, socket, transport]) do
    Logger.debug("[smtp] start worker")
    domains = Application.get_env(:skirnir, :domains)
    hostname = Application.get_env(:skirnir, :hostname)
    send = fn(data) -> transport.send(socket, data) end
    {address, name} = gethostinfo(socket)
    id = Storage.gen_id()
    Logger.info("[smtp] [#{id}] connected from #{address} (#{name})")
    {:ok, :init, %StateData{socket: socket,
                            id: id,
                            address: address,
                            remote_name: name,
                            transport: transport,
                            send: send,
                            domains: domains,
                            hostname: hostname,
                            tries: @tries},
     {:next_event, :cast, {:init, ref}}}
  end

  def init(:cast, {:init, ref}, state_data) do
    %StateData{id: id,
               socket: socket,
               transport: transport,
               hostname: hostname} = state_data
    :ok = Ranch.accept_ack(ref)
    Logger.debug ["[smtp] [", id, "] accepted connection"]
    transport.send(socket, error(220, nil, hostname))
    transport.setopts(socket, [{:active, :once}])
    {:next_state, :hello, state_data}
  end

  # --------------------------------------------------------------------------
  # hello state
  # --------------------------------------------------------------------------
  def hello(:cast, {:hello, host}, state_data) do
    %StateData{send: send, hostname: hostname, id: id} = state_data
    # TODO: check host or not, depending on configuration
    Logger.debug ["[smtp] [", id, "] received HELO: ", host]
    send.("250 #{hostname}\r\n")
    {:next_state, :mail_from,
     %StateData{state_data | host: host, tries: @tries}}
  end

  def hello(:cast, {:hello_extended, host}, %StateData{tls: false} = state_data) do
    %StateData{send: send, hostname: hostname, id: id} = state_data
    # TODO: check host or not, depending on configuration
    Logger.debug ["[smtp] [#{id}] received EHLO: ", host]
    # TODO: add extensions based on developed extensions and configuration
    # TODO: add PIPELINING
    send.("250-#{hostname}\r\n" <>
          "250-SIZE 307200000\r\n" <>
          "250-ETRN\r\n" <>
          "250-STARTTLS\r\n" <>
          "250-AUTH PLAIN LOGIN\r\n" <>
          "250-AUTH=PLAIN LOGIN\r\n" <>
          "250-ENHANCEDSTATUSCODES\r\n" <>
          "250-8BITMIME\r\n" <>
          "250 DSN\r\n")
    {:next_state, :mail_from,
     %StateData{state_data | host: host, tries: @tries}}
  end

  def hello(:cast, {:hello_extended, host}, state_data) do
    %StateData{send: send, hostname: hostname, id: id} = state_data
    # TODO: check host or not, depending on configuration
    Logger.debug fn ->
      "[smtp] [#{id}] received via TLS EHLO: #{host}"
    end
    # TODO: add extensions based on developed extensions and configuration
    # TODO: add PIPELINING
    send.("250-#{hostname}\r\n" <>
          "250-SIZE 307200000\r\n" <>
          "250-ETRN\r\n" <>
          "250-AUTH PLAIN LOGIN\r\n" <>
          "250-AUTH=PLAIN LOGIN\r\n" <>
          "250-ENHANCEDSTATUSCODES\r\n" <>
          "250-8BITMIME\r\n" <>
          "250 DSN\r\n")
    {:next_state, :mail_from,
     %StateData{state_data | host: host, tries: @tries}}
  end

  def hello(:cast, _whatever, %StateData{tries: 0} = state_data) do
    %StateData{send: send, id: id} = state_data
    Logger.error("[smtp] [#{id}] [hello] too much fails")
    send.(error(221, "2.7.0"))
    {:stop, :normal, state_data}
  end

  def hello(:cast, whatever, state_data) do
    %StateData{send: send, tries: tries, id: id} = state_data
    Logger.error("[smtp] [#{id}] [hello] invalid command: " <>
                 "#{inspect(whatever)}")
    send.(error(503))
    {:keep_state, %StateData{state_data | tries: tries - 1}}
  end

  # --------------------------------------------------------------------------
  # mail_from state
  # --------------------------------------------------------------------------
  def mail_from(:cast, {:mail_from, from, _from_domain}, state_data) do
    %StateData{send: send, id: id} = state_data
    # TODO: if from is in the same domain, needs auth?
    Logger.info("[smtp] [#{id}] mail from: <#{from}>")
    send.(error(250))
    {:next_state, :rcpt_to,
     %StateData{state_data | from: from, tries: @tries}}
  end

  def mail_from(:cast, {:error, :bademail}, state_data) do
    Logger.error("[smtp] [#{state_data.id}] bad email direction in " <>
                 "mail_from")
    state_data.send.(error(501, "5.1.7"))
    :keep_state_and_data
  end

  def mail_from(:cast, _whatever, %StateData{tries: 0} = state_data) do
    %StateData{send: send, id: id} = state_data
    Logger.error("[smtp] [#{id}] [mail_from] too much fails")
    send.(error(221, "2.7.0"))
    {:stop, :normal, state_data}
  end

  def mail_from(:cast, whatever, state_data) do
    %StateData{send: send, tries: tries, id: id} = state_data
    Logger.error("[smtp] [#{id}] [mail_from] invalid command: " <>
                 "#{inspect(whatever)}")
    send.(error(502, "5.5.2"))
    {:keep_state, %StateData{state_data | tries: tries - 1}}
  end

  # --------------------------------------------------------------------------
  # rcpt_to state
  # --------------------------------------------------------------------------
  def rcpt_to(:cast, {:rcpt_to, to, to_domain}, state_data) do
    %StateData{send: send, domains: domains, id: id} = state_data
    is_valid_domain = to_domain in domains
    Logger.debug("[smtp] [#{id}] checking #{inspect(to_domain)} against " <>
                 "#{inspect(domains)}: #{inspect(is_valid_domain)}")
    case Application.get_env(:skirnir, :relay, false) do
      false when not is_valid_domain ->
        Logger.error("[smtp] [#{id}] relay is not permitted")
        send.(error(554, "5.7.1", to))
        :keep_state_and_data
      relay when is_boolean(relay) ->
        Logger.info("[smtp] [#{id}] recipient: <#{to}>")
        send.(error(250))
        recipients = [{to, to_domain} | state_data.recipients]
        newstate = %StateData{state_data | recipients: recipients,
                                           tries: @tries}
        {:keep_state, newstate}
    end
  end

  def rcpt_to(:cast, {:error, :bademail}, state_data) do
    Logger.error("[smtp] [#{state_data.id}] bad email direction in rcpt_to")
    state_data.send.(error(501, "5.1.3"))
    :keep_state_and_data
  end

  def rcpt_to(:cast, :data, state_data) do
    Logger.debug ["[smtp] [", state_data.id, "] sending DATA"]
    state_data.send.(error(354))
    {:next_state, :data, state_data}
  end

  def rcpt_to(:cast, _whatever, %StateData{tries: 0} = state_data) do
    Logger.error("[smtp] [#{state_data.id}] [rcpt_to] too much fails")
    state_data.send.(error(221, "2.7.0"))
    {:stop, :normal, state_data}
  end

  def rcpt_to(:cast, whatever, state_data) do
    Logger.error("[smtp] [#{state_data.id}] [rcpt_to] invalid command: " <>
                 "#{inspect(whatever)}")
    state_data.send.(error(554, "5.5.1"))
    {:keep_state, %StateData{state_data | tries: state_data.tries - 1}}
  end

  # --------------------------------------------------------------------------
  # data state
  # --------------------------------------------------------------------------

  def data(:cast, :data, state_data) do
    id = state_data.id
    email = Email.create(state_data)
    Storage.put(id, email)
    Queue.enqueue(id)
    state_data.send.(error(250, "2.0.0", id))
    newstate = %StateData{state_data | id: Storage.gen_id(),
                                       data: "",
                                       from: nil,
                                       recipients: [],
                                       tries: @tries}
    {:next_state, :hello, newstate}
  end

  def data(:cast, _whatever, state_data) do
    %StateData{send: send, tries: tries} = state_data
    Logger.error("[smtp] [data] trying to send another command, " <>
                 "maybe hacking?")
    send.(error(502, "5.5.2"))
    {:keep_state, %StateData{state_data | tries: tries - 1}}
  end

  # --------------------------------------------------------------------------
  # handle info (errors)
  # --------------------------------------------------------------------------
  def handle_event(:info, {:error, :timeout}, _state, state_data) do
    Logger.info("[smtp] connection close inactivity in #{@timeout}ms")
    {:stop, :normal, state_data}
  end

  def handle_event(:info, {:error, :closed}, _state, state_data) do
    Logger.info("[smtp] connection closed by foreign host")
    {:stop, :normal, state_data}
  end

  def handle_event(:info, {:ssl_closed, _socket}, _state, state_data) do
    Logger.info("[smtp] connection ssl closed by foreign host")
    {:stop, :normal, state_data}
  end

  def handle_event(:info, {:tcp_closed, _socket}, _state, state_data) do
    Logger.info("[smtp] connection tcp closed by foreign host")
    {:stop, :normal, state_data}
  end

  def handle_event(:info, {:error, unknown}, _state, state_data) do
    Logger.info("[smtp] stopping worker: #{inspect unknown}")
    {:stop, :normal, state_data}
  end

  #---------------------------------------------------------------------------
  # handle info with data state
  #---------------------------------------------------------------------------
  def handle_event(:info, {_trans, _port, ".\r\n"}, :data, state_data) do
    state_data.transport.setopts(state_data.socket, [{:active, :once}])
    {:keep_state_and_data, {:next_event, :cast, :data}}
  end

  def handle_event(:info, {_trans, _port, newdata}, :data, state_data) do
    %StateData{socket: socket, transport: transport} = state_data
    transport.setopts(socket, [{:active, :once}])
    case String.ends_with?(newdata, "\r\n.\r\n") do
      true ->
        newdata = state_data.data <> String.slice(newdata, 0..-3)
        {:keep_state, %StateData{state_data | data: newdata},
         {:next_event, :cast, :data}}
      false ->
        newdata = state_data.data <> newdata
        {:keep_state, %StateData{state_data | data: newdata}}
    end
  end

  #---------------------------------------------------------------------------
  # handle info with the rest of states
  #---------------------------------------------------------------------------
  def handle_event(:info, {trans, _port, newdata}, _state_name, state_data) do
    %StateData{socket: socket, transport: transport} = state_data
    Logger.debug fn ->
      "[smtp] [#{state_data.id}] received: #{inspect(newdata)}"
    end
    case parse(newdata) do
      :starttls when trans == :tcp ->
        Logger.debug fn ->
          "[smtp] [#{state_data.id}] changing to TLS"
        end
        transport.setopts(socket, [{:active, :false}])
        state_data.send.("220 2.0.0 Ready to start TLS\n")
        {:ok, ssl_socket} = Tls.accept(socket)
        transport = :ranch_ssl
        transport.setopts(ssl_socket, [{:active, :once}])
        send = fn(data) -> RanchSsl.send(ssl_socket, data) end
        Logger.debug fn ->
          "[smtp] [#{state_data.id}] changed to TLS"
        end
        {:next_state, :hello,
         %StateData{state_data | transport: :ssl,
                                 send: send,
                                 tls: true,
                                 socket: ssl_socket,
                                 tcp_socket: socket}}
      :noop ->
        command_noop(state_data)
      :quit ->
        command_quit(state_data)
      command ->
        transport.setopts(socket, [{:active, :once}])
        {:keep_state_and_data, {:next_event, :cast, command}}
    end
  end

  def handle_event(type, msg, state_name, state_data) do
    apply(__MODULE__, state_name, [type, msg, state_data])
  end

  # --------------------------------------------------------------------------
  # general commands
  # --------------------------------------------------------------------------

  defp command_noop(state_data) do
    state_data.send.(error(250, "2.0.0"))
    state_data.transport.setopts(state_data.socket, [{:active, :once}])
    :keep_state_and_data
  end

  defp command_quit(state_data) do
    state_data.send.(error(221))
    Logger.info("[smtp] [#{state_data.id}] connection closed by " <>
                "foreign host")
    state_data.transport.setopts(state_data.socket, [{:active, :once}])
    {:stop, :normal, state_data}
  end

  # --------------------------------------------------------------------------
  # terminate
  # --------------------------------------------------------------------------
  def terminate(_reason, _state_name,
                %StateData{socket: socket, transport: transport}) do
    transport.close(socket)
  end

end
