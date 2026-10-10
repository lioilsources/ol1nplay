package playback

import (
	"math/rand"

	"github.com/ol1n/ol1nplay/engine/protocol"
)

// queue is the play order. tracks is the user-visible list; order is a
// permutation of indices when shuffle is on (nil = sequential); pos is the
// position in order of the track the device is on (-1 = nothing).
type queue struct {
	tracks  []protocol.Track
	order   []int
	pos     int
	repeat  string // "off" | "one" | "all"
	shuffle bool
	rnd     *rand.Rand
}

func newQueue() *queue {
	return &queue{pos: -1, repeat: "off", rnd: rand.New(rand.NewSource(rand.Int63()))}
}

func (q *queue) len() int { return len(q.tracks) }

// idxAt maps a position in play order to a track index.
func (q *queue) idxAt(p int) int {
	if p < 0 || p >= len(q.tracks) {
		return -1
	}
	if q.order != nil {
		return q.order[p]
	}
	return p
}

// posOf maps a track index to its position in play order.
func (q *queue) posOf(idx int) int {
	if q.order == nil {
		return idx
	}
	for p, i := range q.order {
		if i == idx {
			return p
		}
	}
	return -1
}

func (q *queue) currentIdx() int { return q.idxAt(q.pos) }

func (q *queue) current() (protocol.Track, bool) {
	i := q.currentIdx()
	if i < 0 {
		return protocol.Track{}, false
	}
	return q.tracks[i], true
}

// peekNext returns the play-order position that follows the current one
// under the repeat mode, without moving. ok=false means the queue ends.
func (q *queue) peekNext() (int, bool) {
	if len(q.tracks) == 0 {
		return -1, false
	}
	if q.repeat == "one" && q.pos >= 0 {
		return q.pos, true
	}
	n := q.pos + 1
	if n >= len(q.tracks) {
		if q.repeat == "all" {
			return 0, true
		}
		return -1, false
	}
	return n, true
}

// next moves to the following track; "one" repeat is honoured only when
// natural (user skips always move on).
func (q *queue) next(natural bool) bool {
	if len(q.tracks) == 0 {
		return false
	}
	if natural {
		p, ok := q.peekNext()
		if !ok {
			return false
		}
		q.pos = p
		return true
	}
	n := q.pos + 1
	if n >= len(q.tracks) {
		if q.repeat == "all" || q.repeat == "one" {
			n = 0
		} else {
			return false
		}
	}
	q.pos = n
	return true
}

func (q *queue) prev() bool {
	if len(q.tracks) == 0 {
		return false
	}
	n := q.pos - 1
	if n < 0 {
		if q.repeat == "off" {
			n = 0
		} else {
			n = len(q.tracks) - 1
		}
	}
	q.pos = n
	return true
}

func (q *queue) jump(idx int) bool {
	if idx < 0 || idx >= len(q.tracks) {
		return false
	}
	q.pos = q.posOf(idx)
	return true
}

func (q *queue) set(tracks []protocol.Track, idx int) {
	q.tracks = append([]protocol.Track(nil), tracks...)
	q.pos = -1
	q.reshuffle(idx)
	if idx >= 0 && idx < len(q.tracks) {
		q.pos = q.posOf(idx)
	}
}

func (q *queue) add(tracks []protocol.Track) {
	start := len(q.tracks)
	q.tracks = append(q.tracks, tracks...)
	if q.order != nil {
		// New tracks are shuffled into the not-yet-played tail.
		tail := make([]int, 0, len(tracks))
		for i := range tracks {
			tail = append(tail, start+i)
		}
		q.rnd.Shuffle(len(tail), func(i, j int) { tail[i], tail[j] = tail[j], tail[i] })
		q.order = append(q.order, tail...)
	}
}

// insert places tracks right after the current track in play order.
func (q *queue) insert(tracks []protocol.Track) {
	if q.pos < 0 || q.order != nil {
		// Simplest correct behaviour under shuffle: play-next in order.
		cur := q.currentIdx()
		q.tracks = append(q.tracks, tracks...)
		if q.order != nil {
			n := len(q.tracks) - len(tracks)
			ins := make([]int, len(tracks))
			for i := range tracks {
				ins[i] = n + i
			}
			at := q.pos + 1
			q.order = append(q.order[:at], append(ins, q.order[at:]...)...)
			if cur >= 0 {
				q.pos = q.posOf(cur)
			}
		} else if q.pos < 0 {
			q.pos = -1
		}
		return
	}
	at := q.pos + 1
	q.tracks = append(q.tracks[:at], append(append([]protocol.Track(nil), tracks...), q.tracks[at:]...)...)
}

func (q *queue) remove(idx int) {
	if idx < 0 || idx >= len(q.tracks) {
		return
	}
	cur := q.currentIdx()
	q.tracks = append(q.tracks[:idx], q.tracks[idx+1:]...)
	if q.order != nil {
		no := q.order[:0]
		for _, i := range q.order {
			if i == idx {
				continue
			}
			if i > idx {
				i--
			}
			no = append(no, i)
		}
		q.order = no
	}
	switch {
	case cur == idx:
		if q.pos >= len(q.tracks) {
			q.pos = len(q.tracks) - 1
		}
	case cur > idx:
		q.pos = q.posOf(cur - 1)
	}
}

func (q *queue) move(from, to int) {
	n := len(q.tracks)
	if from < 0 || from >= n || to < 0 || to >= n || from == to {
		return
	}
	cur := q.currentIdx()
	t := q.tracks[from]
	q.tracks = append(q.tracks[:from], q.tracks[from+1:]...)
	q.tracks = append(q.tracks[:to], append([]protocol.Track{t}, q.tracks[to:]...)...)
	remap := func(i int) int {
		switch {
		case i == from:
			return to
		case from < to && i > from && i <= to:
			return i - 1
		case to < from && i >= to && i < from:
			return i + 1
		}
		return i
	}
	if q.order != nil {
		for k := range q.order {
			q.order[k] = remap(q.order[k])
		}
	}
	if cur >= 0 {
		q.pos = q.posOf(remap(cur))
	}
}

func (q *queue) clear() {
	q.tracks = nil
	q.order = nil
	q.pos = -1
}

// setShuffle regenerates the play order; the current track stays current
// and becomes the first of the shuffled sequence so "shuffle" never
// re-plays what you already heard.
func (q *queue) setShuffle(on bool) {
	cur := q.currentIdx()
	q.shuffle = on
	q.reshuffle(cur)
	if cur >= 0 {
		q.pos = q.posOf(cur)
	}
}

func (q *queue) reshuffle(cur int) {
	if !q.shuffle || len(q.tracks) == 0 {
		q.order = nil
		return
	}
	q.order = make([]int, 0, len(q.tracks))
	for i := range q.tracks {
		if i != cur {
			q.order = append(q.order, i)
		}
	}
	q.rnd.Shuffle(len(q.order), func(i, j int) { q.order[i], q.order[j] = q.order[j], q.order[i] })
	if cur >= 0 && cur < len(q.tracks) {
		q.order = append([]int{cur}, q.order...)
	}
}

func (q *queue) snapshot() protocol.Queue {
	return protocol.Queue{
		Index:   q.currentIdx(),
		Tracks:  append([]protocol.Track(nil), q.tracks...),
		Shuffle: q.shuffle,
		Repeat:  q.repeat,
	}
}
