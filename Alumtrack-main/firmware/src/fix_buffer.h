#pragma once

#include <Arduino.h>
#include "config.h"

/**
 * One GPS fix, packed small enough that a few hundred fit comfortably in RAM.
 *
 * `recordedAt` is epoch millis when the device clock is valid, and 0 when the
 * tracker has not yet learned the time (no GPS date and no server response).
 * The server substitutes arrival time for a zero/implausible stamp.
 */
struct Fix {
  double lat;
  double lng;
  float speedKph;
  float headingDeg;
  float hdop;
  uint8_t satellites;
  uint64_t recordedAt;
};

/**
 * Fixed-capacity ring buffer.
 *
 * Overwrites the oldest fix when full: on a long outage the freshest history
 * is what matters, and a bus that has been offline for an hour should not
 * flush an hour of stale positions on reconnect.
 */
class FixBuffer {
 public:
  void push(const Fix &fix) {
    buffer_[head_] = fix;
    head_ = (head_ + 1) % BUFFER_CAPACITY;
    if (size_ < BUFFER_CAPACITY) {
      size_++;
    } else {
      tail_ = (tail_ + 1) % BUFFER_CAPACITY;
      dropped_++;
    }
  }

  /** Copies up to `max` oldest fixes into `out` without consuming them. */
  size_t peek(Fix *out, size_t max) const {
    const size_t n = size_ < max ? size_ : max;
    for (size_t i = 0; i < n; i++) {
      out[i] = buffer_[(tail_ + i) % BUFFER_CAPACITY];
    }
    return n;
  }

  /** Drops the oldest `n` fixes, after they have been acknowledged. */
  void consume(size_t n) {
    const size_t take = size_ < n ? size_ : n;
    tail_ = (tail_ + take) % BUFFER_CAPACITY;
    size_ -= take;
  }

  size_t size() const { return size_; }
  bool empty() const { return size_ == 0; }
  uint32_t dropped() const { return dropped_; }

 private:
  Fix buffer_[BUFFER_CAPACITY];
  size_t head_ = 0;
  size_t tail_ = 0;
  size_t size_ = 0;
  uint32_t dropped_ = 0;
};
