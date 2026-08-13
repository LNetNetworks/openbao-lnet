// Firma de un digest crudo de 32 bytes con secp256k1.
//
// Copiar este archivo a backend/path_sign_digest.go en el FORK de
// kaleido-io/vault-plugin-secrets-ethsign, y aplicar paths.patch para que
// paths() registre la ruta nueva.
//
// A diferencia de path_sign.go (que arma un types.Transaction y firma
// keccak256(RLP(tx))), este endpoint firma el hash TAL CUAL:
//   - sin envolverlo en una transacción,
//   - sin el prefijo EIP-191 ("\x19Ethereum Signed Message:\n32"),
//   - sin re-hashear.
//
// crypto.Sign devuelve 65 bytes R||S||V con V en {0,1} y S canónica (low-s,
// EIP-2), que es exactamente lo que necesita ecrecover.

package backend

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/hashicorp/vault/sdk/framework"
	"github.com/hashicorp/vault/sdk/logical"
)

func pathSignDigest(b *backend) *framework.Path {
	return &framework.Path{
		Pattern:      "accounts/" + framework.GenericNameRegex("name") + "/sign-digest",
		HelpSynopsis: "Sign a raw 32-byte digest with secp256k1.",
		HelpDescription: `

    Sign a raw 32-byte digest with the account's secp256k1 key. The digest is
    signed as-is: no EIP-191 prefix is applied and the input is not re-hashed.
    Returns the recoverable signature (r, s, v) with canonical low-s, so that
    ecrecover(hash, v, r, s) yields the account address.

    `,
		Fields: map[string]*framework.FieldSchema{
			"name": &framework.FieldSchema{Type: framework.TypeString},
			"hash": &framework.FieldSchema{
				Type:        framework.TypeString,
				Description: "The 32-byte digest to sign, hex encoded (with or without the '0x' prefix).",
			},
			"digest": &framework.FieldSchema{
				Type:        framework.TypeString,
				Description: "Alias of 'hash'. Used only when 'hash' is empty.",
			},
		},
		ExistenceCheck: b.pathExistenceCheck,
		Callbacks: map[logical.Operation]framework.OperationFunc{
			logical.CreateOperation: b.signDigest,
			logical.UpdateOperation: b.signDigest,
		},
	}
}

func (b *backend) signDigest(ctx context.Context, req *logical.Request, data *framework.FieldData) (*logical.Response, error) {
	from := data.Get("name").(string)

	input := data.Get("hash").(string)
	if input == "" {
		input = data.Get("digest").(string)
	}
	if input == "" {
		return nil, fmt.Errorf("Missing 'hash' field")
	}
	if len(input) > 2 && input[0:2] != "0x" {
		input = "0x" + input
	}

	digest, err := hexutil.Decode(input)
	if err != nil {
		b.Logger().Error("Failed to decode payload for the 'hash' field", "error", err)
		return nil, fmt.Errorf("Invalid 'hash' value: must be hex encoded")
	}
	if len(digest) != 32 {
		// crypto.Sign también lo rechazaría, pero el error de acá es explícito.
		return nil, fmt.Errorf("Invalid 'hash' length: got %d bytes, want exactly 32", len(digest))
	}

	account, err := b.retrieveAccount(ctx, req, from)
	if err != nil {
		b.Logger().Error("Failed to retrieve the signing account", "address", from, "error", err)
		return nil, fmt.Errorf("Error retrieving signing account %s", from)
	}
	if account == nil {
		return nil, fmt.Errorf("Signing account %s does not exist", from)
	}

	privateKey, err := crypto.HexToECDSA(account.PrivateKey)
	if err != nil {
		b.Logger().Error("Error reconstructing private key from retrieved hex", "error", err)
		return nil, fmt.Errorf("Error reconstructing private key from retrieved hex")
	}
	defer ZeroKey(privateKey)

	sig, err := crypto.Sign(digest, privateKey)
	if err != nil {
		b.Logger().Error("Failed to sign the digest", "error", err)
		return nil, err
	}

	return &logical.Response{
		Data: map[string]interface{}{
			"address":   account.Address,
			"hash":      hexutil.Encode(digest),
			"signature": hexutil.Encode(sig), // 0x + r(32) + s(32) + v(1) == 65 bytes
			"r":         hexutil.Encode(sig[0:32]),
			"s":         hexutil.Encode(sig[32:64]),
			"v":         int(sig[64]),      // 0 | 1  (recovery id crudo)
			"v_eth":     int(sig[64]) + 27, // 27 | 28 (lo que espera ecrecover de Solidity)
		},
	}, nil
}
