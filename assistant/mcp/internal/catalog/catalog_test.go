package catalog

import (
	"slices"
	"strings"
	"testing"
)

func TestReviewedCatalogIsExactAndFailClosed(t *testing.T) {
	definitions := Definitions()
	if len(definitions) != 70 {
		t.Fatalf("tool count = %d, want 70", len(definitions))
	}
	if err := Validate(definitions); err != nil {
		t.Fatal(err)
	}
	names := Names()
	if !slices.IsSorted(names) {
		t.Fatal("names are not sorted")
	}
	for _, name := range names {
		definition, ok := Lookup(name)
		if !ok {
			t.Fatalf("missing lookup for %s", name)
		}
		if definition.Scope == "*" || strings.Contains(definition.Scope, "*") {
			t.Fatalf("wildcard scope on %s", name)
		}
		for _, prohibited := range []string{"delete", "destroy", "purge", "request", "shell", "filesystem"} {
			if strings.Contains(name, prohibited) {
				t.Fatalf("prohibited tool %s", name)
			}
		}
	}
}

func TestValidateRejectsDuplicateRoutesWildcardsAndGenericTools(t *testing.T) {
	base := Definitions()[0]
	duplicate := base
	duplicate.Name = "another_tool"
	if err := Validate([]Definition{base, duplicate}); err == nil {
		t.Fatal("duplicate route accepted")
	}

	wildcard := base
	wildcard.Scope = "*"
	if err := Validate([]Definition{wildcard}); err == nil {
		t.Fatal("wildcard scope accepted")
	}

	generic := base
	generic.Name = "request"
	if err := Validate([]Definition{generic}); err == nil {
		t.Fatal("generic request tool accepted")
	}
}
