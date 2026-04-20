defmodule Zed.Secrets.GenerateTest do
  use ExUnit.Case, async: true

  alias Zed.Secrets.Generate

  describe "random_256_b64/0" do
    test "produces ≥ 32 characters of base64url" do
      value = Generate.random_256_b64()
      # 32 bytes → 43 chars base64url without padding
      assert byte_size(value) == 43
      assert value =~ ~r/^[A-Za-z0-9_\-]+$/
    end

    test "two calls produce distinct values" do
      refute Generate.random_256_b64() == Generate.random_256_b64()
    end
  end

  describe "pbkdf2_sha256/2" do
    test "produces PHC-formatted hash" do
      hash = Generate.pbkdf2_sha256("correct-horse-battery-staple")
      assert hash =~ ~r/^\$pbkdf2-sha256\$i=600000\$[A-Za-z0-9+\/]+\$[A-Za-z0-9+\/]+$/
    end

    test "different passwords produce different hashes" do
      refute Generate.pbkdf2_sha256("a") == Generate.pbkdf2_sha256("b")
    end

    test "same password with different salt produces different hash" do
      salt_a = :crypto.strong_rand_bytes(16)
      salt_b = :crypto.strong_rand_bytes(16)
      refute Generate.pbkdf2_sha256("same", salt: salt_a) ==
               Generate.pbkdf2_sha256("same", salt: salt_b)
    end

    test "deterministic for fixed salt" do
      salt = :crypto.strong_rand_bytes(16)

      assert Generate.pbkdf2_sha256("same", salt: salt, iterations: 1000) ==
               Generate.pbkdf2_sha256("same", salt: salt, iterations: 1000)
    end

    test "iteration count appears in output" do
      hash = Generate.pbkdf2_sha256("pw", iterations: 12345)
      assert hash =~ "i=12345"
    end
  end

  describe "ed25519/0" do
    test "returns %{priv, pub} with 32-byte binaries" do
      %{priv: priv, pub: pub} = Generate.ed25519()
      assert byte_size(priv) == 32
      assert byte_size(pub) == 32
    end

    test "two calls produce distinct keys" do
      a = Generate.ed25519()
      b = Generate.ed25519()
      refute a.priv == b.priv
      refute a.pub == b.pub
    end

    test "generated keypair can sign and verify" do
      %{priv: priv, pub: pub} = Generate.ed25519()
      msg = "zed bootstrap kickoff"
      sig = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519])
      assert :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])
    end
  end

  describe "random_passphrase/1" do
    test "default length is 16 bytes (22 chars base64url)" do
      assert byte_size(Generate.random_passphrase()) == 22
    end

    test "custom length" do
      assert byte_size(Generate.random_passphrase(8)) == 11
    end
  end

  describe "by_algo/2 dispatch" do
    test ":random_256_b64 returns {:ok, binary}" do
      assert {:ok, v} = Generate.by_algo(:random_256_b64, [])
      assert is_binary(v)
    end

    test ":pbkdf2_sha256 auto-generates plaintext when not supplied" do
      assert {:ok, %{plaintext: pt, hash: hash}} = Generate.by_algo(:pbkdf2_sha256, [])
      assert byte_size(pt) > 0
      assert hash =~ "pbkdf2-sha256"
    end

    test ":pbkdf2_sha256 honours supplied :plaintext" do
      assert {:ok, %{plaintext: "my-password", hash: _}} =
               Generate.by_algo(:pbkdf2_sha256, plaintext: "my-password")
    end

    test ":ed25519 returns {:ok, %{priv, pub}}" do
      assert {:ok, %{priv: priv, pub: pub}} = Generate.by_algo(:ed25519, [])
      assert byte_size(priv) == 32
      assert byte_size(pub) == 32
    end

    test "unknown algo returns {:error, {:unknown_algo, _}}" do
      assert {:error, {:unknown_algo, :moon_math}} = Generate.by_algo(:moon_math, [])
    end
  end
end
