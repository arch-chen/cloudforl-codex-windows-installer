package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/opt"
)

type writeRequest struct {
	Origin string            `json:"origin"`
	Items  map[string]string `json:"items"`
}

type receipt struct {
	Success bool   `json:"success"`
	Origin  string `json:"origin,omitempty"`
	Items   int    `json:"items,omitempty"`
	Found   bool   `json:"found,omitempty"`
	Value   string `json:"value,omitempty"`
	Error   string `json:"error,omitempty"`
}

func encodeBlinkString(value string) []byte {
	latin1 := true
	for _, character := range value {
		if character > 0xff {
			latin1 = false
			break
		}
	}

	if latin1 {
		encoded := make([]byte, 1, len(value)+1)
		encoded[0] = 1
		for _, character := range value {
			encoded = append(encoded, byte(character))
		}
		return encoded
	}

	units := utf16.Encode([]rune(value))
	encoded := make([]byte, 1+len(units)*2)
	encoded[0] = 0
	for index, unit := range units {
		binary.LittleEndian.PutUint16(encoded[1+index*2:], unit)
	}
	return encoded
}

func decodeBlinkString(encoded []byte) (string, error) {
	if len(encoded) == 0 {
		return "", errors.New("empty Blink string")
	}
	switch encoded[0] {
	case 1:
		runes := make([]rune, len(encoded)-1)
		for index, value := range encoded[1:] {
			runes[index] = rune(value)
		}
		return string(runes), nil
	case 0:
		if (len(encoded)-1)%2 != 0 {
			return "", errors.New("invalid UTF-16 Blink string")
		}
		units := make([]uint16, (len(encoded)-1)/2)
		for index := range units {
			units[index] = binary.LittleEndian.Uint16(encoded[1+index*2:])
		}
		return string(utf16.Decode(units)), nil
	default:
		return "", fmt.Errorf("unknown Blink string marker %d", encoded[0])
	}
}

func localStorageKey(origin string, scriptKey string) []byte {
	prefix := append([]byte("_"+origin), 0)
	return append(prefix, encodeBlinkString(scriptKey)...)
}

func decodeLocalStorageKey(raw []byte) (origin string, scriptKey string, ok bool) {
	if len(raw) < 4 || raw[0] != '_' {
		return "", "", false
	}
	separator := -1
	for index := 1; index < len(raw); index++ {
		if raw[index] == 0 {
			separator = index
			break
		}
	}
	if separator < 0 || separator+1 >= len(raw) {
		return "", "", false
	}
	decoded, err := decodeBlinkString(raw[separator+1:])
	if err != nil {
		return "", "", false
	}
	return string(raw[1:separator]), decoded, true
}

func listKeys(dbPath string, prefix string, showValues bool) error {
	database, err := leveldb.OpenFile(dbPath, &opt.Options{ReadOnly: true, ErrorIfMissing: true})
	if err != nil {
		return err
	}
	defer database.Close()

	iterator := database.NewIterator(nil, nil)
	defer iterator.Release()
	for iterator.Next() {
		origin, key, ok := decodeLocalStorageKey(iterator.Key())
		if !ok || !strings.HasPrefix(key, prefix) {
			continue
		}
		if !showValues {
			fmt.Printf("%s\t%s\n", origin, key)
			continue
		}
		value, decodeErr := decodeBlinkString(iterator.Value())
		if decodeErr != nil {
			fmt.Printf("%s\t%s\t<decode-error:%v>\n", origin, key, decodeErr)
			continue
		}
		fmt.Printf("%s\t%s\t%s\n", origin, key, value)
	}
	return iterator.Error()
}

func appendProtoVarintField(target []byte, fieldNumber uint64, value uint64) []byte {
	target = appendVarint(target, fieldNumber<<3)
	return appendVarint(target, value)
}

func appendVarint(target []byte, value uint64) []byte {
	for value >= 0x80 {
		target = append(target, byte(value)|0x80)
		value >>= 7
	}
	return append(target, byte(value))
}

func chromiumTimeInternalValue() uint64 {
	const windowsToUnixEpochMicroseconds = int64(11644473600000000)
	return uint64(time.Now().UnixMicro() + windowsToUnixEpochMicroseconds)
}

func localStorageMetadata(totalSize uint64) (writeMetadata []byte, accessMetadata []byte) {
	now := chromiumTimeInternalValue()
	writeMetadata = appendProtoVarintField(writeMetadata, 1, now)
	writeMetadata = appendProtoVarintField(writeMetadata, 2, totalSize)
	accessMetadata = appendProtoVarintField(accessMetadata, 1, now)
	return writeMetadata, accessMetadata
}

func writeItems(dbPath string, inputPath string, create bool) error {
	input, err := os.ReadFile(inputPath)
	if err != nil {
		return err
	}
	var request writeRequest
	if err := json.Unmarshal(input, &request); err != nil {
		return err
	}
	if request.Origin == "" {
		return errors.New("origin is required")
	}
	if len(request.Items) == 0 {
		return errors.New("at least one item is required")
	}

	database, err := leveldb.OpenFile(dbPath, &opt.Options{ErrorIfMissing: !create})
	if err != nil {
		return err
	}
	defer database.Close()

	keys := make([]string, 0, len(request.Items))
	for key := range request.Items {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	batch := new(leveldb.Batch)
	var totalSize uint64
	for _, key := range keys {
		encodedKey := localStorageKey(request.Origin, key)
		encodedValue := encodeBlinkString(request.Items[key])
		batch.Put(encodedKey, encodedValue)
		totalSize += uint64(len(encodedKey) + len(encodedValue))
	}
	if create {
		writeMetadata, accessMetadata := localStorageMetadata(totalSize)
		batch.Put([]byte("VERSION"), []byte("1"))
		batch.Put([]byte("META:"+request.Origin), writeMetadata)
		batch.Put([]byte("METAACCESS:"+request.Origin), accessMetadata)
	}
	if err := database.Write(batch, &opt.WriteOptions{Sync: true}); err != nil {
		return err
	}
	for _, key := range keys {
		stored, getErr := database.Get(localStorageKey(request.Origin, key), nil)
		if getErr != nil {
			return fmt.Errorf("verify %s: %w", key, getErr)
		}
		decoded, decodeErr := decodeBlinkString(stored)
		if decodeErr != nil || decoded != request.Items[key] {
			return fmt.Errorf("verify %s: value mismatch", key)
		}
	}

	return json.NewEncoder(os.Stdout).Encode(receipt{Success: true, Origin: request.Origin, Items: len(keys)})
}

func readItem(dbPath string, origin string, key string) error {
	if origin == "" {
		return errors.New("origin is required")
	}
	database, err := leveldb.OpenFile(dbPath, &opt.Options{ReadOnly: true, ErrorIfMissing: true})
	if err != nil {
		return err
	}
	defer database.Close()

	stored, err := database.Get(localStorageKey(origin, key), nil)
	if errors.Is(err, leveldb.ErrNotFound) {
		return json.NewEncoder(os.Stdout).Encode(receipt{Success: true, Origin: origin, Found: false})
	}
	if err != nil {
		return err
	}
	decoded, err := decodeBlinkString(stored)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(receipt{Success: true, Origin: origin, Found: true, Value: decoded})
}

func main() {
	dbPath := flag.String("db", "", "Chromium Local Storage LevelDB directory")
	inputPath := flag.String("input", "", "JSON file containing origin and items")
	create := flag.Bool("create", false, "create and initialize a Chromium Local Storage database")
	origin := flag.String("origin", "", "localStorage security origin")
	getKey := flag.String("get-key", "", "read one decoded localStorage key")
	listPrefix := flag.String("list-prefix", "", "list decoded localStorage keys with this prefix")
	showValues := flag.Bool("show-values", false, "show decoded values while listing")
	flag.Parse()

	if *dbPath == "" {
		_ = json.NewEncoder(os.Stdout).Encode(receipt{Success: false, Error: "db is required"})
		os.Exit(2)
	}

	var err error
	if *getKey != "" {
		err = readItem(*dbPath, *origin, *getKey)
	} else if *listPrefix != "" {
		err = listKeys(*dbPath, *listPrefix, *showValues)
	} else if *inputPath != "" {
		err = writeItems(*dbPath, *inputPath, *create)
	} else {
		err = errors.New("input, get-key, or list-prefix is required")
	}
	if err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(receipt{Success: false, Error: err.Error()})
		os.Exit(1)
	}
}
