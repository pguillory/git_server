defmodule GitServer.StateTest do
  use ExUnit.Case, async: true
  import GitServer.State
  alias GitServer.State

  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)

  test "round trip" do
    state = %State{
      head: "refs/heads/master",
      packs: [@b, @a],
      refs: %{"refs/tags/v1" => @a, "refs/heads/x" => @b},
    }

    assert encode(state) == """
           git_server state 1
           head refs/heads/master
           pack #{@b}
           pack #{@a}
           ref #{@b} refs/heads/x
           ref #{@a} refs/tags/v1
           """

    assert decode(encode(state)) == {:ok, state}

    assert decode(encode(new())) ==
             {:ok, %State{head: "refs/heads/main", packs: [], refs: %{}}}
  end

  test "malformed states" do
    for text <- [
          "",
          "other\n",
          "git_server state 1",
          "git_server state 1\n",
          "git_server state 1\nhead refs/heads/main",
          "git_server state 1\nhead refs/heads/main\nhead refs/heads/x\n",
          "git_server state 1\nhead refs/heads/main\npack #{String.upcase(@a)}\n",
          "git_server state 1\nhead refs/heads/main\npack #{@a}\npack #{@a}\n",
          "git_server state 1\nhead refs/heads/main\nref #{@a} refs/b\nref #{@a} refs/a\n",
          "git_server state 1\nhead refs/heads/main\nref #{@a} refs/a\nref #{@a} refs/a\n",
          "git_server state 1\nhead refs/heads/main\nref #{@a} refs/a b\n",
          "git_server state 1\nhead refs/heads/main\nref #{@a}\n",
          "git_server state 1\nhead refs/heads/main\nextra\n",
        ] do
      assert {:error, _} = decode(text), inspect(text)
    end
  end
end
