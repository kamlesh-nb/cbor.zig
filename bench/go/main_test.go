package main

import (
	"fmt"
	"testing"

	"github.com/fxamacker/cbor/v2"
)

type NestedStruct struct {
	ID     uint64    `cbor:"id"`
	Name   string    `cbor:"name"`
	Values []float64 `cbor:"values"`
	Flags  []bool    `cbor:"flags"`
}

type TestData struct {
	SmallInt     uint32       `cbor:"small_int"`
	MediumString string       `cbor:"medium_string"`
	LargeArray   []uint64     `cbor:"large_array"`
	NestedStruct NestedStruct `cbor:"nested_struct"`
}

func createTestData() TestData {
	values := make([]float64, 50)
	for i := range values {
		values[i] = float64(i) * 0.1
	}

	flags := make([]bool, 20)
	for i := range flags {
		flags[i] = i%2 == 0
	}

	largeArray := make([]uint64, 1000)
	for i := range largeArray {
		largeArray[i] = uint64(i * i)
	}

	return TestData{
		SmallInt:     42,
		MediumString: "This is a medium string for complex data testing",
		LargeArray:   largeArray,
		NestedStruct: NestedStruct{
			ID:     999999,
			Name:   "complex_nested_structure_with_long_name",
			Values: values,
			Flags:  flags,
		},
	}
}

func BenchmarkEncodeInteger(b *testing.B) {
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

func BenchmarkEncodeString(b *testing.B) {
	testStrings := []string{
		"A",
		"Hello, World!",
		"This is a medium-length string for testing CBOR encoding performance.",
		"Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
	}

	for _, testString := range testStrings {
		b.Run(fmt.Sprintf("string_len_%d", len(testString)), func(b *testing.B) {
			b.ResetTimer()
			for j := 0; j < b.N; j++ {
				_, err := cbor.Marshal(testString)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkEncodeArray(b *testing.B) {
	// Small array
	smallArray := []uint32{1, 2, 3, 4, 5}
	b.Run("small", func(b *testing.B) {
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
	b.Run("medium", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(mediumArray)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Large array
	largeArray := make([]uint64, 10000)
	for i := range largeArray {
		largeArray[i] = uint64(i)
	}
	b.Run("large", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(largeArray)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}

func BenchmarkEncodeStruct(b *testing.B) {
	type SimpleStruct struct {
		ID    uint64  `cbor:"id"`
		Name  string  `cbor:"name"`
		Value float64 `cbor:"value"`
	}

	testStruct := SimpleStruct{
		ID:    12345,
		Name:  "test_name",
		Value: 3.14159,
	}

	b.Run("single", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(testStruct)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Complex nested struct
	complexData := createTestData()
	b.Run("array", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			_, err := cbor.Marshal(complexData)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}

func BenchmarkDecodeInteger(b *testing.B) {
	testValues := []uint64{0, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296}

	for _, value := range testValues {
		encoded, _ := cbor.Marshal(value)
		b.Run(fmt.Sprintf("integer_%d", value), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				var decoded uint64
				err := cbor.Unmarshal(encoded, &decoded)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkDecodeString(b *testing.B) {
	testStrings := []string{
		"A",
		"Hello, World!",
		"This is a medium-length string for testing CBOR encoding performance.",
	}

	for _, testString := range testStrings {
		encoded, _ := cbor.Marshal(testString)
		b.Run(fmt.Sprintf("string_len_%d", len(testString)), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				var decoded string
				err := cbor.Unmarshal(encoded, &decoded)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkDecodeArray(b *testing.B) {
	// Small array
	smallArray := []uint32{1, 2, 3, 4, 5}
	smallEncoded, _ := cbor.Marshal(smallArray)
	b.Run("small", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			var decoded []uint32
			err := cbor.Unmarshal(smallEncoded, &decoded)
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
	mediumEncoded, _ := cbor.Marshal(mediumArray)
	b.Run("medium", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			var decoded []uint64
			err := cbor.Unmarshal(mediumEncoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Large array
	largeArray := make([]uint64, 10000)
	for i := range largeArray {
		largeArray[i] = uint64(i)
	}
	largeEncoded, _ := cbor.Marshal(largeArray)
	b.Run("large", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			var decoded []uint64
			err := cbor.Unmarshal(largeEncoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}

func BenchmarkDecodeStruct(b *testing.B) {
	type SimpleStruct struct {
		ID    uint64  `cbor:"id"`
		Name  string  `cbor:"name"`
		Value float64 `cbor:"value"`
	}

	testStruct := SimpleStruct{
		ID:    12345,
		Name:  "test_name",
		Value: 3.14159,
	}
	simpleEncoded, _ := cbor.Marshal(testStruct)

	b.Run("single", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			var decoded SimpleStruct
			err := cbor.Unmarshal(simpleEncoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Complex nested struct
	complexData := createTestData()
	complexEncoded, _ := cbor.Marshal(complexData)
	b.Run("array", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			var decoded TestData
			err := cbor.Unmarshal(complexEncoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}

func BenchmarkRoundtrip(b *testing.B) {
	// Array roundtrip
	testArray := make([]uint64, 100)
	for i := range testArray {
		testArray[i] = uint64(i)
	}
	b.Run("array", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			encoded, err := cbor.Marshal(testArray)
			if err != nil {
				b.Fatal(err)
			}
			var decoded []uint64
			err = cbor.Unmarshal(encoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Struct roundtrip
	testData := createTestData()
	b.Run("struct", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			encoded, err := cbor.Marshal(testData)
			if err != nil {
				b.Fatal(err)
			}
			var decoded TestData
			err = cbor.Unmarshal(encoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})

	// Map roundtrip
	testMap := make(map[string]uint64)
	for i := 0; i < 50; i++ {
		testMap[fmt.Sprintf("key_%d", i)] = uint64(i)
	}
	b.Run("map", func(b *testing.B) {
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			encoded, err := cbor.Marshal(testMap)
			if err != nil {
				b.Fatal(err)
			}
			var decoded map[string]uint64
			err = cbor.Unmarshal(encoded, &decoded)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}
