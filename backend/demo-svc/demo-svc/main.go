package main

import (
	"fmt"

	// A-6 test: pulls in an old golang.org/x/net with known HIGH CVEs (HTTP/2 rapid reset, CVE-2023-39325), so Trivy flags the binary.
	_ "golang.org/x/net/http2"
)

// Add returns a+b.
func Add(a, b int) int { return a + b }

func main() { fmt.Println(Add(2, 3)) }
