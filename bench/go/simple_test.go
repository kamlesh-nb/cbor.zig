package main

import (
	"fmt"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

func BenchmarkIntegerEncoding(b *testing.B) {
	testValues := []uint64{0, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296}

	for _, value := range testValues {
		b.Run(fmt.Sprintf("integer_%d", value), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, err := cbor.Marshal(value)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkStringEncoding(b *testing.B) {
	testStrings := []string{
		"A",
		"Hello, World!",
		"This is a medium-length string for testing CBOR encoding performance.",
		"Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
	}

	for _, testString := range testStrings {
		b.Run(fmt.Sprintf("string_len_%d", len(testString)), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				_, err := cbor.Marshal(testString)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkArrayEncoding(b *testing.B) {
	// Small array
	smallArray := []uint32{1, 2, 3, 4, 5}
	b.Run("small_array", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(smallArray)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Medium array
	mediumArray := make([]uint64, 100)
	for i := range mediumArray {
		mediumArray[i] = uint64(i)
	}
	b.Run("medium_array", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(mediumArray)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Large array - only run a few iterations
	largeArray := make([]uint64, 10000)
	for i := range largeArray {
		largeArray[i] = uint64(i)
	}
	b.Run("large_array", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(largeArray)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}
