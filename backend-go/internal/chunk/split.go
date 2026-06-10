package chunk

import "strings"

// Split breaks text into overlapping chunks by paragraphs (\n\n), then by rune length.
func Split(text string, chunkSize, overlap int) []string {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	if chunkSize <= 0 {
		return []string{text}
	}
	step := chunkSize - overlap
	if step < 1 {
		step = 1
	}

	var out []string
	for _, para := range strings.Split(text, "\n\n") {
		p := strings.TrimSpace(para)
		if p == "" {
			continue
		}
		if len([]rune(p)) <= chunkSize {
			out = append(out, p)
			continue
		}
		out = append(out, splitRunes(p, chunkSize, step)...)
	}
	return out
}

func splitRunes(s string, size, step int) []string {
	r := []rune(s)
	var out []string
	for i := 0; i < len(r); i += step {
		j := i + size
		if j > len(r) {
			j = len(r)
		}
		out = append(out, string(r[i:j]))
		if j >= len(r) {
			break
		}
	}
	return out
}
