"""The Mock Turtle's timetable.

The Mock Turtle attended lessons for a fixed number of hours on the first day, then one hour less
on every day after, until there were none left. This module is that arithmetic.
"""

from __future__ import annotations


class Timetable:
    """Lesson hours for a day of the Mock Turtle's schedule.

    The first day has ``first_day_hours`` hours of lessons; each following day has one hour fewer,
    never dropping below zero.
    """

    def __init__(self, first_day_hours: int = 10) -> None:
        if first_day_hours < 0:
            raise ValueError("first_day_hours must not be negative")
        self.first_day_hours = first_day_hours

    def hours_on_day(self, day: int) -> int:
        """Return the hours of lessons on ``day`` (1 is the first day)."""
        if day < 1:
            raise ValueError("day must be 1 or greater")
        return max(self.first_day_hours - (day - 1), 0)

    def total_hours(self) -> int:
        """Return the total lesson hours across the whole schedule."""
        n = self.first_day_hours
        return n * (n + 1) // 2
