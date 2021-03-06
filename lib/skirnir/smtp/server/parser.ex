defmodule Skirnir.Smtp.Server.Parser do

  def parse(data) do
    data
    |> String.upcase()
    |> command(data)
  end

  def command(<<"HELO ", _ :: binary()>>, <<_ :: size(40), host :: binary()>>) do
    {:hello, String.trim(host)}
  end

  def command(<<"EHLO ", _ :: binary()>>, <<_ :: size(40), host :: binary()>>) do
    {:hello_extended, String.trim(host)}
  end

  def command(<<"STARTTLS", _ :: binary()>>, _), do: :starttls

  def command(<<"MAIL FROM:", _ :: binary()>>, <<_ :: size(80), from :: binary()>>) do
    case parse_email(from) do
      [email, domain] -> {:mail_from, email, domain}
      {:error, :bademail} -> {:error, :bademail}
    end
  end

  def command(<<"RCPT TO:", _ :: binary()>>, <<_ :: size(64), to :: binary()>>) do
    case parse_email(to) do
      [email, domain] -> {:rcpt_to, email, domain}
      {:error, :bademail} -> {:error, :bademail}
    end
  end

  def command(<<"DATA", _ :: binary()>>, _), do: :data
  def command(<<"QUIT", _ :: binary()>>, _), do: :quit
  def command(<<"NOOP", _ :: binary()>>, _), do: :noop

  def parse_header(data) do
    case Regex.run(~r/^([\x21-\x39\x3b-\x7e]+):(.+)$/, data) do
      [_, header, content] ->
        {:header, String.trim(header), String.trim(content)}
      nil ->
        {:continue, String.trim(data)}
    end
  end

  defp parse_email(email) do
    case validate_email(String.trim(email)) do
      {:ok, email, host} -> [email, host]
      {:error, :bademail} -> {:error, :bademail}
    end
  end

  defp validate_email(email) do
    email_regex = ~r/^<[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}>$/
    case Regex.run(email_regex, email) do
      nil ->
        {:error, :bademail}
      [email] ->
        case Regex.run(~r/<(\w+@([\w.]+))>/, email) do
          [_, clean_email, host] ->
            {:ok, clean_email, host}
          _ ->
            {:error, :bademail}
        end
    end
  end

end
