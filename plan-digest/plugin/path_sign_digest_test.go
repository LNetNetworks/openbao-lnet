// Test del endpoint sign-digest. Copiar a backend/path_sign_digest_test.go en
// el fork del plugin y correr con `go test ./...` (getBackend viene de
// backend/accounts_test.go, upstream).
//
// Esta es LA verificación que importa: comprueba con go-ethereum que
// ecrecover(digest, firma) == address de la cuenta, que la firma es low-s y que
// el digest NO se re-hashea ni se le aplica el prefijo EIP-191.

package backend

import (
	"context"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/hashicorp/vault/sdk/logical"
	"github.com/stretchr/testify/assert"
)

func TestSignDigest(t *testing.T) {
	b, storage := getBackend(t)
	ctx := context.Background()

	// Cuenta nueva
	req := logical.TestRequest(t, logical.UpdateOperation, "accounts")
	req.Storage = storage
	res, err := b.HandleRequest(ctx, req)
	assert.NoError(t, err)
	address := res.Data["address"].(string)

	digest := crypto.Keccak256([]byte("credentialHash de prueba"))

	req = logical.TestRequest(t, logical.CreateOperation, "accounts/"+address+"/sign-digest")
	req.Storage = storage
	req.Data["hash"] = hexutil.Encode(digest)
	res, err = b.HandleRequest(ctx, req)
	assert.NoError(t, err)
	assert.NotNil(t, res)

	sig, err := hexutil.Decode(res.Data["signature"].(string))
	assert.NoError(t, err)
	assert.Equal(t, 65, len(sig))

	// r || s || v coherentes con el campo `signature`
	assert.Equal(t, hexutil.Encode(sig[0:32]), res.Data["r"].(string))
	assert.Equal(t, hexutil.Encode(sig[32:64]), res.Data["s"].(string))
	assert.Equal(t, int(sig[64]), res.Data["v"].(int))
	assert.Equal(t, int(sig[64])+27, res.Data["v_eth"].(int))
	assert.True(t, res.Data["v"].(int) == 0 || res.Data["v"].(int) == 1)

	// ecrecover(digest, sig) == address de la cuenta
	pub, err := crypto.SigToPub(digest, sig)
	assert.NoError(t, err)
	assert.Equal(t,
		strings.ToLower(address),
		strings.ToLower(crypto.PubkeyToAddress(*pub).Hex()))

	// low-s (EIP-2): s <= N/2
	s := new(big.Int).SetBytes(sig[32:64])
	halfN := new(big.Int).Rsh(crypto.S256().Params().N, 1)
	assert.True(t, s.Cmp(halfN) <= 0, "la firma debe ser low-s")

	// El digest se firma tal cual: la firma NO valida contra el hash con
	// prefijo EIP-191 ni contra keccak(digest).
	prefixed := accounts.TextHash(digest)
	pubPrefixed, err := crypto.SigToPub(prefixed, sig)
	assert.NoError(t, err)
	assert.NotEqual(t,
		strings.ToLower(address),
		strings.ToLower(crypto.PubkeyToAddress(*pubPrefixed).Hex()),
		"si esto coincide, se está aplicando el prefijo EIP-191")

	rehashed := crypto.Keccak256(digest)
	pubRehashed, err := crypto.SigToPub(rehashed, sig)
	assert.NoError(t, err)
	assert.NotEqual(t,
		strings.ToLower(address),
		strings.ToLower(crypto.PubkeyToAddress(*pubRehashed).Hex()),
		"si esto coincide, se está re-hasheando el digest")

	// Sin '0x' también funciona
	req = logical.TestRequest(t, logical.CreateOperation, "accounts/"+address+"/sign-digest")
	req.Storage = storage
	req.Data["hash"] = hexutil.Encode(digest)[2:]
	res, err = b.HandleRequest(ctx, req)
	assert.NoError(t, err)
	assert.Equal(t, hexutil.Encode(digest), res.Data["hash"].(string))
}

func TestSignDigestRejectsBadInput(t *testing.T) {
	b, storage := getBackend(t)
	ctx := context.Background()

	req := logical.TestRequest(t, logical.UpdateOperation, "accounts")
	req.Storage = storage
	res, err := b.HandleRequest(ctx, req)
	assert.NoError(t, err)
	address := res.Data["address"].(string)

	failsWith := func(hash string) {
		r := logical.TestRequest(t, logical.CreateOperation, "accounts/"+address+"/sign-digest")
		r.Storage = storage
		r.Data["hash"] = hash
		resp, err := b.HandleRequest(ctx, r)
		assert.True(t, err != nil || (resp != nil && resp.IsError()),
			"debería fallar con hash=%q", hash)
	}

	failsWith("")                              // falta el campo
	failsWith("0xdeadbeef")                    // 4 bytes, no 32
	failsWith("0x" + strings.Repeat("ab", 33)) // 33 bytes
	failsWith("no-es-hex")

	// Cuenta inexistente
	r := logical.TestRequest(t, logical.CreateOperation,
		"accounts/0xf809410b0d6f047c603deb311979cd413e025a84/sign-digest")
	r.Storage = storage
	r.Data["hash"] = hexutil.Encode(crypto.Keccak256([]byte("x")))
	resp, err := b.HandleRequest(ctx, r)
	assert.True(t, err != nil || (resp != nil && resp.IsError()))
}
