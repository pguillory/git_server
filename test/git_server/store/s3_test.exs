defmodule GitServer.Store.S3Test do
  use ExUnit.Case, async: true
  alias GitServer.Store
  import GitServer.Store.S3, only: [check_endpoint: 1, check_prefix: 1]

  test "endpoint and prefix checks" do
    assert check_endpoint("https://example.com") == :ok
    assert check_endpoint("http://localhost:9000") == :ok
    assert check_endpoint("http://127.0.0.5") == :ok
    assert check_endpoint("http://[::1]:9000") == :ok
    assert check_endpoint("http://example.com") == {:error, :insecure}
    assert check_endpoint("https://example.com/path") == {:error, :not_url}
    assert check_endpoint("ftp://example.com") == {:error, :not_url}
    assert check_endpoint("https://key:secret@example.com") == {:error, :not_url}
    assert check_endpoint("https://example.com?x=1") == {:error, :not_url}
    assert check_endpoint("https://example.com#x") == {:error, :not_url}
    assert check_prefix("") == :ok
    assert check_prefix("a/b/") == :ok
    assert check_prefix("a") == {:error, :no_trailing_slash}
    assert check_prefix("a b/") == {:error, :invalid_characters}
  end

  test "new checks its settings and keeps the secret out of inspect" do
    settings = [
      endpoint: "https://example.com",
      bucket: "b",
      region: "auto",
      access_key_id: "id",
      secret_access_key: "very-secret",
    ]

    assert {:ok, {GitServer.Store.S3, config}} = GitServer.Store.S3.new(settings)
    assert config.prefix == ""
    refute inspect(config) =~ "very-secret"

    assert {:error, "missing S3 settings: bucket"} =
             GitServer.Store.S3.new(Keyword.delete(settings, :bucket))

    assert {:error, _} =
             GitServer.Store.S3.new(Keyword.put(settings, :endpoint, "http://example.com"))

    assert {:error, _} = GitServer.Store.S3.new(Keyword.put(settings, :prefix, "p"))
  end

  test "get, put, list and delete" do
    store = GitServer.TestStore.fresh()
    assert Store.get(store, "a/b") == {:error, :not_found}
    assert {:ok, etag} = Store.put(store, "a/b", "hello", :none)
    assert Store.get(store, "a/b") == {:ok, "hello", etag}
    assert {:ok, _} = Store.put(store, "a/c d", "x", :none)
    assert {:ok, _} = Store.put(store, "b", "", :none)

    assert {:ok, [%{key: "a/b", etag: ^etag, size: 5}, %{key: "a/c d", size: 1}]} =
             Store.list(store, "a/")

    assert {:ok, [_, _, %{key: "b", size: 0}]} = Store.list(store, "")
    assert Store.delete(store, "a/b") == :ok
    assert Store.delete(store, "a/b") == :ok
    assert Store.get(store, "a/b") == {:error, :not_found}
  end

  test "conditional puts" do
    store = GitServer.TestStore.fresh()
    assert {:ok, e1} = Store.put(store, "k", "one", :absent)
    assert Store.put(store, "k", "two", :absent) == {:error, :precondition_failed}

    assert Store.put(store, "k", "two", {:etag, "0123456789abcdef0123456789abcdef"}) ==
             {:error, :precondition_failed}

    assert {:ok, e2} = Store.put(store, "k", "two", {:etag, e1})
    assert Store.put(store, "k", "three", {:etag, e1}) == {:error, :precondition_failed}
    assert Store.get(store, "k") == {:ok, "two", e2}

    assert Store.put(store, "missing", "x", {:etag, e2}) in [
             {:error, :precondition_failed},
             {:error, :not_found},
           ]
  end

  test "two writers racing on one etag: exactly one wins" do
    store = GitServer.TestStore.fresh()
    {:ok, e0} = Store.put(store, "state", "base", :none)

    for round <- 1..10 do
      {:ok, _, etag} = Store.get(store, "state")
      assert round == 1 or etag != e0

      results =
        [1, 2]
        |> Enum.map(fn writer ->
          Task.async(fn -> Store.put(store, "state", "#{round}-#{writer}", {:etag, etag}) end)
        end)
        |> Task.await_many()

      assert [{:error, :precondition_failed}, {:ok, winner_etag}] = Enum.sort(results)
      assert {:ok, body, ^winner_etag} = Store.get(store, "state")
      assert body in ["#{round}-1", "#{round}-2"]
    end
  end

  test "two writers racing to create: exactly one wins" do
    store = GitServer.TestStore.fresh()

    for round <- 1..10 do
      results =
        [1, 2]
        |> Enum.map(fn writer ->
          Task.async(fn -> Store.put(store, "new-#{round}", "#{writer}", :absent) end)
        end)
        |> Task.await_many()

      assert [{:error, :precondition_failed}, {:ok, _}] = Enum.sort(results)
    end
  end

  @tag :tmp_dir
  test "files stream both ways", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    source = Path.join(tmp_dir, "source")
    body = :crypto.strong_rand_bytes(300_000)
    File.write!(source, body)
    assert {:ok, etag} = Store.put_file(store, "big", source, :absent)
    assert Store.put_file(store, "big", source, :absent) == {:error, :precondition_failed}

    target = Path.join(tmp_dir, "target")
    assert Store.get_file(store, "big", target) == {:ok, etag}
    assert File.read!(target) == body

    missing = Path.join(tmp_dir, "missing")
    assert Store.get_file(store, "nothing", missing) == {:error, :not_found}
    refute File.exists?(missing)
    assert {:error, "cannot create " <> _} = Store.get_file(store, "big", target)
  end
end
