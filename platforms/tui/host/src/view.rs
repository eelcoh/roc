//! The screen as the punk app describes it (`View.to_host` in `platforms/tui/View.roc`), and how
//! it is drawn with ratatui.
//!
//! The text has one node per line, its children after it:
//!
//! - `E`: nothing.
//! - `P<n>`: a paragraph of `n` lines; `I<n> <selected>`: a list of `n` lines, one highlighted.
//!   Each line is `L<k>`, then `k` spans `S<attrs>\t<text>` (attrs: `b`, `d`, `i`, `u`, `r`,
//!   `f<colour>`, `g<colour>`, separated by commas).
//! - `C<n>` and `R<n>`: `n` views above each other, or beside each other.
//! - `Z<size>`: the next view is this many rows (in a column) or columns (in a row).
//! - `B<title>`: a frame with this title around the next view.
//!
//! A description the host can't read is drawn as what it could read: the app can't make the
//! host fail.

use std::cell::RefCell;

use ambit_tui::layout::{Constraint, Direction, Layout};
use ambit_tui::style::{Color, Modifier, Style};
use ambit_tui::text::{Line, Span};
use ambit_tui::widgets::{StatefulWidget, Widget};
use ambit_tui::{Buffer, Rect};
use ratatui_widgets::block::Block;
use ratatui_widgets::borders::Borders;
use ratatui_widgets::list::{List, ListState};
use ratatui_widgets::paragraph::Paragraph;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Node {
    #[default]
    Empty,
    Paragraph(Vec<Vec<(Style, String)>>),
    Pick(i64, Vec<Vec<(Style, String)>>),
    Column(Vec<Node>),
    Row(Vec<Node>),
    Sized(u16, Box<Node>),
    Block(String, Box<Node>),
}

/// A view, with where each of its lists was scrolled to the last time it was drawn, so that a
/// list moves only when its selection would leave the screen.
#[derive(Debug, Default)]
pub struct View {
    root: Node,
    offsets: RefCell<Vec<usize>>,
}

impl View {
    pub fn parse(text: &str) -> Self {
        let mut lines = text.lines();
        Self {
            root: node(&mut lines),
            offsets: RefCell::new(Vec::new()),
        }
    }

    pub fn root(&self) -> &Node {
        &self.root
    }

    pub fn render(&self, area: Rect, buf: &mut Buffer) {
        let mut offsets = self.offsets.borrow_mut();
        let mut next = 0;
        draw(&self.root, area, buf, &mut offsets, &mut next);
    }
}

impl Clone for View {
    fn clone(&self) -> Self {
        Self {
            root: self.root.clone(),
            offsets: RefCell::new(self.offsets.borrow().clone()),
        }
    }
}

fn node<'a>(lines: &mut impl Iterator<Item = &'a str>) -> Node {
    let Some(line) = lines.next() else {
        return Node::Empty;
    };
    let (tag, rest) = line.split_at(line.chars().next().map_or(0, char::len_utf8));
    match tag {
        "P" => Node::Paragraph(text_lines(count(rest), lines)),
        "I" => {
            let (n, selected) = rest.split_once(' ').unwrap_or((rest, "-1"));
            let selected = selected.parse().unwrap_or(-1);
            Node::Pick(selected, text_lines(count(n), lines))
        }
        "C" => Node::Column((0..count(rest)).map(|_| node(lines)).collect()),
        "R" => Node::Row((0..count(rest)).map(|_| node(lines)).collect()),
        "Z" => Node::Sized(rest.parse().unwrap_or(0), Box::new(node(lines))),
        "B" => Node::Block(rest.to_string(), Box::new(node(lines))),
        _ => Node::Empty,
    }
}

fn count(text: &str) -> usize {
    text.parse().unwrap_or(0)
}

fn text_lines<'a>(
    n: usize,
    lines: &mut impl Iterator<Item = &'a str>,
) -> Vec<Vec<(Style, String)>> {
    (0..n)
        .map(|_| {
            let spans = lines
                .next()
                .and_then(|l| l.strip_prefix('L'))
                .map_or(0, count);
            (0..spans)
                .filter_map(|_| {
                    let span = lines.next()?.strip_prefix('S')?;
                    let (attrs, text) = span.split_once('\t').unwrap_or((span, ""));
                    Some((style(attrs), text.to_string()))
                })
                .collect()
        })
        .collect()
}

fn style(attrs: &str) -> Style {
    attrs
        .split(',')
        .filter(|a| !a.is_empty())
        .fold(Style::default(), |s, a| match a.split_at(1) {
            ("b", _) => s.add_modifier(Modifier::BOLD),
            ("d", _) => s.add_modifier(Modifier::DIM),
            ("i", _) => s.add_modifier(Modifier::ITALIC),
            ("u", _) => s.add_modifier(Modifier::UNDERLINED),
            ("r", _) => s.add_modifier(Modifier::REVERSED),
            ("f", c) => s.fg(color(c)),
            ("g", c) => s.bg(color(c)),
            _ => s,
        })
}

fn color(code: &str) -> Color {
    match code {
        "0" => Color::Black,
        "1" => Color::Red,
        "2" => Color::Green,
        "3" => Color::Yellow,
        "4" => Color::Blue,
        "5" => Color::Magenta,
        "6" => Color::Cyan,
        "7" => Color::Gray,
        "8" => Color::DarkGray,
        "9" => Color::LightRed,
        "10" => Color::LightGreen,
        "11" => Color::LightYellow,
        "12" => Color::LightBlue,
        "13" => Color::LightMagenta,
        "14" => Color::LightCyan,
        "15" => Color::White,
        _ => Color::Reset,
    }
}

fn to_lines(lines: &[Vec<(Style, String)>]) -> Vec<Line<'_>> {
    lines
        .iter()
        .map(|spans| {
            Line::from(
                spans
                    .iter()
                    .map(|(style, text)| Span::styled(text.as_str(), *style))
                    .collect::<Vec<_>>(),
            )
        })
        .collect()
}

fn draw(node: &Node, area: Rect, buf: &mut Buffer, offsets: &mut Vec<usize>, next: &mut usize) {
    match node {
        Node::Empty => {}
        Node::Paragraph(lines) => Paragraph::new(to_lines(lines)).render(area, buf),
        Node::Pick(selected, lines) => {
            let i = *next;
            *next += 1;
            if offsets.len() <= i {
                offsets.resize(i + 1, 0);
            }
            let selected = usize::try_from(*selected).ok().filter(|s| *s < lines.len());
            let mut state = ListState::default()
                .with_offset(offsets[i])
                .with_selected(selected);
            let list = List::new(to_lines(lines))
                .highlight_style(Style::default().add_modifier(Modifier::REVERSED));
            StatefulWidget::render(list, area, buf, &mut state);
            offsets[i] = state.offset();
        }
        Node::Column(children) => split(Direction::Vertical, children, area, buf, offsets, next),
        Node::Row(children) => split(Direction::Horizontal, children, area, buf, offsets, next),
        Node::Sized(_, child) => draw(child, area, buf, offsets, next),
        Node::Block(title, child) => {
            let block = Block::default().borders(Borders::ALL).title(title.as_str());
            let inner = block.inner(area);
            block.render(area, buf);
            draw(child, inner, buf, offsets, next);
        }
    }
}

fn split(
    direction: Direction,
    children: &[Node],
    area: Rect,
    buf: &mut Buffer,
    offsets: &mut Vec<usize>,
    next: &mut usize,
) {
    let constraints = children.iter().map(|c| match c {
        Node::Sized(n, _) => Constraint::Length(*n),
        _ => Constraint::Fill(1),
    });
    let areas = Layout::default()
        .direction(direction)
        .constraints(constraints)
        .split(area);
    for (child, area) in children.iter().zip(areas.iter()) {
        draw(child, *area, buf, offsets, next);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(view: &View, width: u16, height: u16) -> String {
        let area = Rect::new(0, 0, width, height);
        let mut buf = Buffer::empty(area);
        view.render(area, &mut buf);
        (0..height)
            .map(|y| {
                let line: String = (0..width).map(|x| buf[(x, y)].symbol()).collect();
                line.trim_end().to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn a_column_gives_sized_views_their_rows_and_the_rest_the_remainder() {
        let view = View::parse(
            "C3\nZ1\nP1\nL1\nSb\ttop\nBList\nI3 1\nL1\nS\ta\nL1\nS\tb\nL1\nS\tc\nZ1\nP1\nL2\nS\tx\nSf3\ty",
        );
        assert_eq!(
            screen(&view, 10, 7),
            "top\n┌List────┐\n│a       │\n│b       │\n│c       │\n└────────┘\nxy"
        );
    }

    #[test]
    fn a_list_scrolls_to_keep_its_selection_in_sight() {
        let lines: String = (0..10).map(|i| format!("\nL1\nS\t{i}")).collect();
        let view = View::parse(&format!("I10 7{lines}"));
        assert_eq!(screen(&view, 3, 3), "5\n6\n7");
    }

    #[test]
    fn what_the_host_cant_read_is_drawn_as_far_as_it_goes() {
        let view = View::parse("C2\nP1\nL1\nS\tok\nX");
        assert_eq!(screen(&view, 4, 2), "ok\n");
    }
}
