defmodule Zed.Secrets.VerifyTest do
  use ExUnit.Case, async: true

  alias Zed.Secrets.{Generate, Verify}

  describe "password/2" do
    test "verifies a freshly-generated hash" do
      hash = Generate.pbkdf2_sha256("correct-horse-battery-staple", iterations: 1000)
      assert Verify.password("correct-horse-battery-staple", hash)
    end

    test "rejects wrong password" do
      hash = Generate.pbkdf2_sha256("right", iterations: 1000)
      refute Verify.password("wrong", hash)
    end

    test "rejects when stored hash is garbled" do
      refute Verify.password("pw", "not-a-phc-string")
    end

    test "rejects on nil inputs without raising" do
      refute Verify.password(nil, "$pbkdf2-sha256$i=1$aaa$bbb")
      refute Verify.password("pw", nil)
    end

    test "verifies default 600k iterations hash end-to-end" do
      hash = Generate.pbkdf2_sha256("real-password")
      assert Verify.password("real-password", hash)
      refute Verify.password("real-passwordx", hash)
    end

    test "matches Generate output byte-for-byte" do
      salt = :crypto.strong_rand_bytes(16)
      hash1 = Generate.pbkdf2_sha256("p", salt: salt, iterations: 1000)
      hash2 = Generate.pbkdf2_sha256("p", salt: salt, iterations: 1000)
      assert hash1 == hash2
      assert Verify.password("p", hash1)
      assert Verify.password("p", hash2)
    end
  end
end
