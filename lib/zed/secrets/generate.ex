defmodule Zed.Secrets.Generate do
  @moduledoc """
  Secret-generation primitives used by `Zed.Bootstrap`.

  All algorithms use Erlang's `:crypto` for randomness and primitives.
  No external dependencies — every function here is reviewable against
  its respective RFC or NIST specification.

  Algorithm choices:
    - Random 256-bit values (beam cookies, tokens): 32 bytes from
      `:crypto.strong_rand_bytes/1`, base64url-encoded without padding.
    - Password hashing: PBKDF2-HMAC-SHA256 at 600_000 iterations (NIST
      SP 800-132 recommendation as of 2023). PHC-formatted output so
      the verifier in Layer A2a can parse `iterations` + `salt` out of
      the stored string. Rotation to argon2id is possible later without
      slot-catalog changes (the `algo` tag is the contract, not the
      specific primitive).
    - Ed25519 keypair: `:crypto.generate_key(:eddsa, :ed25519)` —
      returns raw public + private bytes.
  """

  # ----------------------------------------------------------------------
  # Individual algorithms
  # ----------------------------------------------------------------------

  @doc "32 bytes of cryptographic randomness, base64url without padding."
  def random_256_b64 do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  PBKDF2-HMAC-SHA256 hash of `plaintext` in PHC string format.

  Output shape: `$pbkdf2-sha256$i=600000$<salt_b64>$<hash_b64>`.
  Salt is 16 bytes from `strong_rand_bytes/1`.
  Output key length is 32 bytes.
  """
  @pbkdf2_default_iters 600_000
  @pbkdf2_salt_bytes 16
  @pbkdf2_key_bytes 32

  def pbkdf2_sha256(plaintext, opts \\ []) when is_binary(plaintext) do
    iters = Keyword.get(opts, :iterations, @pbkdf2_default_iters)
    salt = Keyword.get(opts, :salt, :crypto.strong_rand_bytes(@pbkdf2_salt_bytes))
    hash = :crypto.pbkdf2_hmac(:sha256, plaintext, salt, iters, @pbkdf2_key_bytes)

    salt_b64 = Base.encode64(salt, padding: false)
    hash_b64 = Base.encode64(hash, padding: false)
    "$pbkdf2-sha256$i=#{iters}$#{salt_b64}$#{hash_b64}"
  end

  @doc """
  Ed25519 keypair. Returns `%{priv: <32 bytes>, pub: <32 bytes>}`.
  """
  def ed25519 do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{priv: priv, pub: pub}
  end

  @doc """
  Random passphrase suitable for humans to store in a password manager.

  16 bytes of randomness, base64url without padding (≈22 characters,
  ~128 bits of entropy). Used as the default for `admin_passwd` when
  the operator did not supply one.
  """
  def random_passphrase(bytes \\ 16) do
    :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  end

  # ----------------------------------------------------------------------
  # Algo dispatch — called by Zed.Bootstrap with the slot's algo tag
  # ----------------------------------------------------------------------

  @doc """
  Generate material for a slot given its `algo` tag and options.

  Return shapes vary per algo:
    - `:random_256_b64` → `{:ok, binary()}` — single value
    - `:pbkdf2_sha256`  → `{:ok, %{plaintext: binary(), hash: binary()}}`
    - `:ed25519`        → `{:ok, %{priv: binary(), pub: binary()}}`

  Options:
    - `:plaintext` (for `:pbkdf2_sha256`): operator-supplied password;
      if omitted, a `random_passphrase/0` is generated.
  """
  def by_algo(:random_256_b64, _opts), do: {:ok, random_256_b64()}

  def by_algo(:pbkdf2_sha256, opts) do
    plaintext = Keyword.get(opts, :plaintext) || random_passphrase()
    hash = pbkdf2_sha256(plaintext)
    {:ok, %{plaintext: plaintext, hash: hash}}
  end

  def by_algo(:ed25519, _opts), do: {:ok, ed25519()}

  def by_algo(other, _opts), do: {:error, {:unknown_algo, other}}
end
