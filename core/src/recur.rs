//! Recurrence arithmetic on calendar dates.

use jiff::{civil::Date, Span, ToSpan};

use crate::model::{Freq, Repeat};

pub const DATE_FMT: &str = "%Y-%m-%d";

/// Splits `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM` into the date and the time suffix
/// (including the `T`, empty when there is none).
pub fn split(value: &str) -> Option<(Date, &str)> {
    let date = Date::strptime(DATE_FMT, value.get(..10)?).ok()?;
    Some((date, &value[10..]))
}

pub fn shift(value: &str, days: i64) -> Option<String> {
    let (date, time) = split(value)?;
    let shifted = date.checked_add(Span::new().try_days(days).ok()?).ok()?;
    Some(format!("{}{}", shifted.strftime(DATE_FMT), time))
}

/// n-th (1..5) or last (-1) given weekday of a month; a missing fifth falls back to the last.
fn nth_weekday(first: Date, nth: i32, weekday: u32) -> Option<Date> {
    let offset = (i64::from(weekday) - i64::from(first.weekday().to_monday_one_offset())).rem_euclid(7);
    let first_hit = first.checked_add(offset.days()).ok()?;
    let mut hits = Vec::new();
    let mut d = first_hit;
    while d.month() == first.month() {
        hits.push(d);
        let Ok(next) = d.checked_add(7.days()) else { break };
        d = next;
    }
    if nth < 0 || nth as usize > hits.len() {
        hits.last().copied()
    } else {
        hits.get((nth.max(1) - 1) as usize).copied()
    }
}

fn step(rule: &Repeat, from: Date) -> Option<Date> {
    let interval = rule.interval.max(1);
    match rule.freq {
        Freq::Daily => from.checked_add(Span::new().try_days(i64::from(interval)).ok()?).ok(),
        Freq::Weekly => {
            let mut days: Vec<i64> = rule
                .weekdays
                .iter()
                .filter(|d| (1..=7).contains(*d))
                .map(|d| *d as i64)
                .collect();
            days.sort_unstable();
            days.dedup();
            if days.is_empty() {
                return from.checked_add(Span::new().try_weeks(i64::from(interval)).ok()?).ok();
            }
            let today = from.weekday().to_monday_one_offset() as i64;
            match days.iter().find(|d| **d > today) {
                Some(next) => from.checked_add((next - today).days()).ok(),
                None => {
                    let monday = from.checked_sub((today - 1).days()).ok()?;
                    let next_week = monday
                        .checked_add(Span::new().try_weeks(i64::from(interval)).ok()?)
                        .ok()?;
                    next_week.checked_add((days[0] - 1).days()).ok()
                }
            }
        }
        Freq::Monthly => {
            let target = from
                .first_of_month()
                .checked_add(Span::new().try_months(i64::from(interval)).ok()?)
                .ok()?;
            match (rule.nth, rule.nth_weekday) {
                (Some(nth), Some(wd)) if (1..=7).contains(&wd) => nth_weekday(target, nth, wd),
                _ => {
                    let day = rule.monthday.unwrap_or(from.day() as u32);
                    target
                        .with()
                        .day(day.clamp(1, target.days_in_month() as u32) as i8)
                        .build()
                        .ok()
                }
            }
        }
        Freq::Yearly => from.checked_add(Span::new().try_years(i64::from(interval)).ok()?).ok(),
    }
}

/// Date of the occurrence that follows `current`, or `None` when the rule is exhausted.
///
/// `current` is the date of the occurrence being completed (due date, else start
/// date), `done` is the completion date. Occurrences already in the past are
/// skipped, so an overdue task never lands on another overdue date.
pub fn next_occurrence(rule: &Repeat, current: Option<Date>, done: Date) -> Option<Date> {
    if rule.count == Some(0) || rule.count == Some(1) {
        return None;
    }
    let anchor = if rule.from_done { done } else { current.unwrap_or(done) };
    let mut next = step(rule, anchor)?;
    let mut guard = 0;
    while next <= done && guard < 10_000 {
        next = step(rule, next)?;
        guard += 1;
    }
    if let Some(until) = rule.until.as_deref().and_then(|u| Date::strptime(DATE_FMT, u).ok()) {
        if next > until {
            return None;
        }
    }
    Some(next)
}

/// Fills in what the rule needs to stay stable across months: a monthly rule
/// without an explicit day remembers the day of the first due date, so that
/// the 31st survives February.
pub fn normalized(mut rule: Repeat, due: Option<&str>) -> Repeat {
    rule.interval = rule.interval.max(1);
    if rule.freq == Freq::Monthly && rule.monthday.is_none() && rule.nth.is_none() && !rule.from_done {
        if let Some((date, _)) = due.and_then(split) {
            rule.monthday = Some(u32::try_from(date.day()).expect("a date's day is positive"));
        }
    }
    rule
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> Date {
        Date::strptime(DATE_FMT, s).unwrap()
    }

    fn rule(freq: Freq, interval: u32) -> Repeat {
        Repeat {
            freq,
            interval,
            weekdays: vec![],
            monthday: None,
            nth: None,
            nth_weekday: None,
            from_done: false,
            count: None,
            until: None,
        }
    }

    #[test]
    fn daily_and_weekly_from_due() {
        assert_eq!(
            next_occurrence(&rule(Freq::Daily, 3), Some(d("2026-10-05")), d("2026-10-05")),
            Some(d("2026-10-08"))
        );
        assert_eq!(
            next_occurrence(&rule(Freq::Weekly, 1), Some(d("2026-10-05")), d("2026-10-05")),
            Some(d("2026-10-12"))
        );
        assert_eq!(
            next_occurrence(&rule(Freq::Weekly, 2), Some(d("2026-10-05")), d("2026-10-03")),
            Some(d("2026-10-19"))
        );
    }

    #[test]
    fn overdue_task_skips_past_occurrences() {
        // Due three weeks ago, completed today (a Monday): next is the coming Monday.
        assert_eq!(
            next_occurrence(&rule(Freq::Weekly, 1), Some(d("2026-09-14")), d("2026-10-05")),
            Some(d("2026-10-12"))
        );
    }

    #[test]
    fn from_completion_date() {
        let mut r = rule(Freq::Daily, 10);
        r.from_done = true;
        assert_eq!(
            next_occurrence(&r, Some(d("2026-09-01")), d("2026-10-05")),
            Some(d("2026-10-15"))
        );
    }

    #[test]
    fn weekdays_within_and_across_weeks() {
        let mut r = rule(Freq::Weekly, 1);
        r.weekdays = vec![1, 2, 3, 4, 5];
        // Monday -> Tuesday, Friday -> Monday.
        assert_eq!(
            next_occurrence(&r, Some(d("2026-10-05")), d("2026-10-05")),
            Some(d("2026-10-06"))
        );
        assert_eq!(
            next_occurrence(&r, Some(d("2026-10-09")), d("2026-10-09")),
            Some(d("2026-10-12"))
        );
        let mut every_other = rule(Freq::Weekly, 2);
        every_other.weekdays = vec![2, 4];
        // Thursday -> Tuesday two weeks later.
        assert_eq!(
            next_occurrence(&every_other, Some(d("2026-10-08")), d("2026-10-08")),
            Some(d("2026-10-20"))
        );
    }

    #[test]
    fn r18_month_end_is_clamped_and_restored() {
        let r = normalized(rule(Freq::Monthly, 1), Some("2026-01-31"));
        assert_eq!(r.monthday, Some(31));
        let feb = next_occurrence(&r, Some(d("2026-01-31")), d("2026-01-31")).unwrap();
        assert_eq!(feb, d("2026-02-28"));
        assert_eq!(next_occurrence(&r, Some(feb), feb), Some(d("2026-03-31")));
    }

    #[test]
    fn quarterly_and_yearly() {
        assert_eq!(
            next_occurrence(&rule(Freq::Monthly, 3), Some(d("2026-11-15")), d("2026-11-15")),
            Some(d("2027-02-15"))
        );
        assert_eq!(
            next_occurrence(&rule(Freq::Yearly, 1), Some(d("2028-02-29")), d("2028-02-29")),
            Some(d("2029-02-28"))
        );
    }

    #[test]
    fn nth_weekday_of_month() {
        let mut r = rule(Freq::Monthly, 1);
        r.nth = Some(1);
        r.nth_weekday = Some(1);
        assert_eq!(
            next_occurrence(&r, Some(d("2026-10-05")), d("2026-10-05")),
            Some(d("2026-11-02"))
        );
        r.nth = Some(-1);
        r.nth_weekday = Some(5);
        assert_eq!(
            next_occurrence(&r, Some(d("2026-10-30")), d("2026-10-30")),
            Some(d("2026-11-27"))
        );
        r.nth = Some(5);
        r.nth_weekday = Some(1);
        // November 2026 has five Mondays, December only four: fall back to the last.
        assert_eq!(
            next_occurrence(&r, Some(d("2026-11-30")), d("2026-11-30")),
            Some(d("2026-12-28"))
        );
    }

    #[test]
    fn count_and_until_end_the_series() {
        let mut r = rule(Freq::Daily, 1);
        r.count = Some(1);
        assert_eq!(next_occurrence(&r, Some(d("2026-10-05")), d("2026-10-05")), None);
        r.count = Some(2);
        assert!(next_occurrence(&r, Some(d("2026-10-05")), d("2026-10-05")).is_some());
        let mut u = rule(Freq::Weekly, 1);
        u.until = Some("2026-10-10".into());
        assert_eq!(next_occurrence(&u, Some(d("2026-10-05")), d("2026-10-05")), None);
    }

    #[test]
    fn shift_keeps_time() {
        assert_eq!(shift("2026-10-05T09:30", 7).as_deref(), Some("2026-10-12T09:30"));
        assert_eq!(shift("2026-12-31", 1).as_deref(), Some("2027-01-01"));
    }

    #[test]
    fn date_arithmetic_returns_none_at_jiff_range_limits() {
        assert_eq!(shift("9999-12-31", 1), None);
        assert_eq!(
            next_occurrence(&rule(Freq::Daily, u32::MAX), Some(d("2026-10-05")), d("2026-10-05")),
            None
        );
    }
}
