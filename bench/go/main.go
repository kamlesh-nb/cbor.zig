package main

import (
	"fmt"
	"time"

	"github.com/fxamacker/cbor/v2"
)

func main() {
	fmt.Println("Go CBOR Simple Performance Test")
	
	// Simple performance test
	start := time.Now()
	iterations := 100000
	
	for i := 0; i < iterations; i++ {
		data, _ := cbor.Marshal(uint64(42))
		var decoded uint64
		cbor.Unmarshal(data, &decoded)
	}
	
	duration := time.Since(start)
	nsPerOp := duration.Nanoseconds() / int64(iterations)
	
	fmt.Printf("Simple roundtrip (uint64): %d ns/op\n", nsPerOp)
}
