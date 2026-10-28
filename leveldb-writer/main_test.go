package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/syndtr/goleveldb/leveldb"
)

func TestBlinkStringRoundTrip(t *testing.T) {
	for _, value := range []string{"statsig.stable_id.685440364", "offline-ok", "简体中文"} {
		encoded := encodeBlinkString(value)
		decoded, err := decodeBlinkString(encoded)
		if err != nil {
			t.Fatalf("decode %q: %v", value, err)
		}
		if decoded != value {
			t.Fatalf("round trip mismatch: got %q want %q", decoded, value)
		}
	}
}

func TestLocalStorageMetadataFormat(t *testing.T) {
	writeMetadata, accessMetadata := localStorageMetadata(1234)
	if len(writeMetadata) < 4 || writeMetadata[0] != 0x08 || writeMetadata[len(writeMetadata)-3] != 0x10 {
		t.Fatalf("unexpected write metadata: %x", writeMetadata)
	}
	if binary.LittleEndian.Uint16([]byte{writeMetadata[len(writeMetadata)-2], writeMetadata[len(writeMetadata)-1]}) == 0 {
		t.Fatalf("size field is empty: %x", writeMetadata)
	}
	if len(accessMetadata) < 2 || accessMetadata[0] != 0x08 {
		t.Fatalf("unexpected access metadata: %x", accessMetadata)
	}
}

func TestChromiumLocalStorageKeyFormat(t *testing.T) {
	key := localStorageKey("app://-", "statsig.stable_id.685440364")
	expected := append([]byte("_app://-\x00\x01"), []byte("statsig.stable_id.685440364")...)
	if !bytes.Equal(key, expected) {
		t.Fatalf("unexpected key bytes: %x", key)
	}
	origin, decodedKey, ok := decodeLocalStorageKey(key)
	if !ok || origin != "app://-" || decodedKey != "statsig.stable_id.685440364" {
		t.Fatalf("unexpected decoded key: origin=%q key=%q ok=%v", origin, decodedKey, ok)
	}
}

func TestCreateChromiumDatabase(t *testing.T) {
	root := t.TempDir()
	databasePath := filepath.Join(root, "leveldb")
	inputPath := filepath.Join(root, "input.json")
	input := []byte(`{"origin":"app://-","items":{"offline.test":"offline-ok"}}`)
	if err := os.WriteFile(inputPath, input, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeItems(databasePath, inputPath, true); err != nil {
		t.Fatal(err)
	}
	database, err := leveldb.OpenFile(databasePath, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()

	version, err := database.Get([]byte("VERSION"), nil)
	if err != nil || string(version) != "1" {
		t.Fatalf("unexpected VERSION: value=%q error=%v", version, err)
	}
	for _, key := range []string{"META:app://-", "METAACCESS:app://-"} {
		value, getErr := database.Get([]byte(key), nil)
		if getErr != nil || len(value) == 0 {
			t.Fatalf("missing %s: value=%x error=%v", key, value, getErr)
		}
	}
	stored, err := database.Get(localStorageKey("app://-", "offline.test"), nil)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeBlinkString(stored)
	if err != nil || decoded != "offline-ok" {
		t.Fatalf("unexpected localStorage value: value=%q error=%v", decoded, err)
	}
}
