from mockturtle.timetable import Timetable


def test_first_day_is_full():
    assert Timetable(first_day_hours=10).hours_on_day(1) == 10


def test_one_hour_less_each_day():
    tt = Timetable(first_day_hours=10)
    assert tt.hours_on_day(4) == 7
    assert tt.hours_on_day(10) == 1


def test_never_negative():
    assert Timetable(first_day_hours=10).hours_on_day(20) == 0


def test_total_hours_is_triangular():
    assert Timetable(first_day_hours=10).total_hours() == 55
