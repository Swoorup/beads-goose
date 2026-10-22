// Command gen prints what beads' own Go types make of each issue in a JSONL
// file on stdin; tests/golden.goose prints the same for the Goose port, and
// `make golden` diffs the two. scripts/golden.sh builds this against the
// internal/types package of a beads checkout.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"golden/types"
)

// exportIssueRecord is cmd/bd's export line (export.go), which lives in
// package main there and so is restated here.
type exportIssueRecord struct {
	RecordType string `json:"_type"`
	*types.IssueWithCounts
	WispPlane bool `json:"wisp_plane,omitempty"`
}

func verdict(err error) string {
	if err != nil {
		return err.Error()
	}
	return "ok"
}

func main() {
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		var issue types.Issue
		if err := json.Unmarshal(line, &issue); err != nil {
			fmt.Printf("error\n")
			continue
		}
		if out, err := json.Marshal(&issue); err != nil {
			fmt.Printf("json\tmarshal-error\n")
		} else {
			fmt.Printf("json\t%s\n", out)
		}
		record := &exportIssueRecord{
			RecordType: "issue",
			IssueWithCounts: &types.IssueWithCounts{
				Issue: &issue, DependencyCount: 1, DependentCount: 2, CommentCount: 3,
			},
			WispPlane: issue.NoHistory,
		}
		if out, err := json.Marshal(record); err != nil {
			fmt.Printf("export\tmarshal-error\n")
		} else {
			fmt.Printf("export\t%s\n", out)
		}
		fmt.Printf("hash\t%s\n", issue.ComputeContentHash())
		fmt.Printf("valid\t%s\n", verdict(issue.Validate()))
		fmt.Printf("import\t%s\n", verdict(issue.ValidateForImport(nil)))
		issue.SetDefaults()
		fmt.Printf("defaults\t%s %s\n", issue.Status, issue.IssueType)
	}
}
