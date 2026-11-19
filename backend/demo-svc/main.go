package main

import (
	"fmt"

	shared "example.test/demo-shared"
)

// Add returns a+b.
func Add(a, b int) int { return a + b }

func main() { fmt.Println(shared.Double(Add(2, 3))) }
