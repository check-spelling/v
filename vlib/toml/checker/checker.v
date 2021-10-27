// Copyright (c) 2021 Lars Pontoppidan. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module checker

import toml.ast
import toml.ast.walker
import toml.util
import toml.token
import toml.scanner
import encoding.utf8

pub const allowed_basic_escape_chars = [`u`, `U`, `b`, `t`, `n`, `f`, `r`, `"`, `\\`]

// utf8_max is the value of hex2int('10FFFF')
const utf8_max = 1114111

// Checker checks a tree of TOML `ast.Value`'s for common errors.
pub struct Checker {
	scanner &scanner.Scanner
}

// check checks the `ast.Value` and all it's children
// for common errors.
pub fn (c Checker) check(n &ast.Value) ? {
	walker.walk(c, n) ?
}

fn (c Checker) visit(value &ast.Value) ? {
	match value {
		ast.Bool {
			c.check_boolean(value) ?
		}
		ast.Number {
			c.check_number(value) ?
		}
		ast.Quoted {
			c.check_quoted(value) ?
		}
		else {
			// TODO add more checks to make BurntSushi/toml-test invalid TOML pass
		}
	}
}

// excerpt returns a string of the token's surroundings
fn (c Checker) excerpt(tp token.Position) string {
	return c.scanner.excerpt(tp.pos, 10)
}

// is_hex_bin_oct_prefixed returns true if `hbo` has either
// of: `0x`, `0o` or `0b` - as a prefix.
// Example: assert is_hex_bin_oct_prefixed('0xAF') == true
// Example: assert is_hex_bin_oct_prefixed('xAF') == false
fn is_hex_bin_oct_prefixed(hbo string) bool {
	return hbo.len > 2 && (hbo.starts_with('0x') || hbo.starts_with('0o') || hbo.starts_with('0b'))
}

// has_repeating returns true if `str` has one or more repeating
// `rune` characters provided in `repeats`.
// Example: assert has_repeating('hello__v.', [`.`,`_`]) == true
// Example: assert has_repeating('hello_v.', [`.`,`_`]) == false
fn has_repeating(str string, repeats []rune) bool {
	for i, r in str {
		if r in repeats && i + 1 < str.len {
			if r == str[i + 1] {
				return true
			}
		}
	}
	return false
}

// check_number returns an error if `num` is not a valid TOML number.
fn (c Checker) check_number(num ast.Number) ? {
	lit := num.text
	lit_lower_case := lit.to_lower()
	if lit in ['0', '0.0', '+0', '-0', '+0.0', '-0.0', '0e0', '+0e0', '-0e0', '0e00'] {
		return
	}

	if lit.contains('_') {
		if lit.starts_with('_') || lit.ends_with('_') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" can not start or end with `_` in ...${c.excerpt(num.pos)}...')
		}
		if lit.contains('__') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" can not have more than one underscore (`_`) in ...${c.excerpt(num.pos)}...')
		}
	}

	mut hex_bin_oct := is_hex_bin_oct_prefixed(lit)
	mut is_bin, mut is_oct, mut is_hex := false, false, false
	is_float := lit_lower_case.all_before('e').contains('.')
	has_exponent_notation := lit_lower_case.contains('e')
	float_decimal_index := lit.index('.') or { -1 }
	// mut is_first_digit := byte(lit[0]).is_digit()
	mut ascii := byte(lit[0]).ascii_str()
	is_sign_prefixed := lit[0] in [`+`, `-`]
	mut lit_sans_sign := lit
	if is_sign_prefixed { // +/- ...
		lit_sans_sign = lit[1..]
		hex_bin_oct = is_hex_bin_oct_prefixed(lit_sans_sign)
		if hex_bin_oct {
			ascii = byte(lit[0]).ascii_str()
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (hex, octal and binary) can not start with `$ascii` in ...${c.excerpt(num.pos)}...')
		}
		// is_first_digit = byte(lit_sans_sign[0]).is_digit()
		if lit.len > 1 && lit_sans_sign.starts_with('0') {
			ascii = byte(lit_sans_sign[0]).ascii_str()
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" can not start with `$ascii` in ...${c.excerpt(num.pos)}...')
		}
	} else {
		if !hex_bin_oct {
			if !is_float && lit[0] == `0` {
				if lit[1] in [`B`, `O`, `X`] {
					return error(@MOD + '.' + @STRUCT + '.' + @FN +
						' numbers like "$lit" only lowercase notation in ...${c.excerpt(num.pos)}...')
				}
				return error(@MOD + '.' + @STRUCT + '.' + @FN +
					' numbers like "$lit" can not start with a zero in ...${c.excerpt(num.pos)}...')
			}

			if is_float && lit[0] == `0` && float_decimal_index > 1 {
				return error(@MOD + '.' + @STRUCT + '.' + @FN +
					' numbers like "$lit" can not start with a zero in ...${c.excerpt(num.pos)}...')
			}
		}
	}

	if has_repeating(lit, [`_`, `.`, `b`, `o`, `x`]) {
		return error(@MOD + '.' + @STRUCT + '.' + @FN +
			' numbers like "$lit" can not have $scanner.digit_extras as repeating characters in ...${c.excerpt(num.pos)}...')
	}

	if hex_bin_oct {
		is_bin = lit_sans_sign.starts_with('0b')
		is_oct = lit_sans_sign.starts_with('0o')
		is_hex = lit_sans_sign.starts_with('0x')

		third := lit[2]
		if third in scanner.digit_extras {
			ascii = byte(third).ascii_str()
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (hex, octal and binary) can not have `$ascii` in ...${c.excerpt(num.pos)}...')
		}
		lit_sans_sign_and_type_prefix := lit_sans_sign[2..]

		if lit_sans_sign_and_type_prefix.starts_with('_')
			|| lit_sans_sign_and_type_prefix.ends_with('_') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" can not start or end with `_` in ...${c.excerpt(num.pos)}...')
		}

		if is_bin {
			if !c.is_valid_binary_literal(lit_sans_sign_and_type_prefix) {
				return error(@MOD + '.' + @STRUCT + '.' + @FN +
					' "$lit" is not a valid binary number in ...${c.excerpt(num.pos)}...')
			}
		} else if is_oct {
			if !c.is_valid_octal_literal(lit_sans_sign_and_type_prefix) {
				return error(@MOD + '.' + @STRUCT + '.' + @FN +
					' "$lit" is not a valid octal number in ...${c.excerpt(num.pos)}...')
			}
		} else {
			if !c.is_valid_hex_literal(lit_sans_sign_and_type_prefix) {
				return error(@MOD + '.' + @STRUCT + '.' + @FN +
					' "$lit" is not a valid hexadecimal number in ...${c.excerpt(num.pos)}...')
			}
		}
	}

	if has_exponent_notation {
		if lit_lower_case.all_after('e').starts_with('_')
			|| lit_lower_case.all_before('e').ends_with('_') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' the exponent in "$lit" can not start nor end with an underscore in ...${c.excerpt(num.pos)}...')
		}
		if lit_lower_case.all_after('e').contains('.') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (with exponent) can not have a decimal point in ...${c.excerpt(num.pos)}...')
		}
		if !is_hex && lit_lower_case.count('e') > 1 {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (with exponent) can only have one exponent in ...${c.excerpt(num.pos)}...')
		}
	}

	if is_float {
		if lit.count('.') > 1 {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (float) can only have one decimal point in ...${c.excerpt(num.pos)}...')
		}
		last := lit[lit.len - 1]
		if last in scanner.digit_extras {
			ascii = byte(last).ascii_str()
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (float) can not start with `$ascii` in ...${c.excerpt(num.pos)}...')
		}
		if lit.contains('_.') || lit.contains('._') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (float) can not have underscores before or after the decimal point in ...${c.excerpt(num.pos)}...')
		}
		if lit_lower_case.contains('e.') || lit.contains('.e') {
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" (float) can not have decimal points on either side of the exponent notation in ...${c.excerpt(num.pos)}...')
		}
	} else {
		if lit.len > 1 && lit.starts_with('0') && lit[1] !in [`b`, `o`, `x`] {
			ascii = byte(lit[0]).ascii_str()
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' numbers like "$lit" can not start with `$ascii` in ...${c.excerpt(num.pos)}...')
		}
	}
}

// is_valid_binary_literal returns true if `num` is valid TOML binary literal.
fn (c Checker) is_valid_binary_literal(num string) bool {
	for ch in num {
		if ch == `_` {
			continue
		}
		if !(ch >= `0` && ch <= `1`) {
			return false
		}
	}
	return true
}

// is_valid_octal_literal returns true if `num` is valid TOML octal literal.
fn (c Checker) is_valid_octal_literal(num string) bool {
	for ch in num {
		if ch == `_` {
			continue
		}
		if !(ch >= `0` && ch <= `7`) {
			return false
		}
	}
	return true
}

// is_valid_hex_literal returns true if `num` is valid TOML hexadecimal literal.
fn (c Checker) is_valid_hex_literal(num string) bool {
	for ch in num {
		if ch == `_` {
			continue
		}
		if !ch.is_hex_digit() {
			return false
		}
	}
	return true
}

// check_boolean returns an error if `b` is not a valid TOML boolean.
fn (c Checker) check_boolean(b ast.Bool) ? {
	lit := b.text
	if lit in ['true', 'false'] {
		return
	}
	return error(@MOD + '.' + @STRUCT + '.' + @FN +
		' boolean values like "$lit" can only be `true` or `false` literals, not `$lit` in ...${c.excerpt(b.pos)}...')
}

// check_quoted returns an error if `q` is not a valid quoted TOML string.
fn (c Checker) check_quoted(q ast.Quoted) ? {
	lit := q.text
	quote := q.quote.ascii_str()
	triple_quote := quote + quote + quote
	if q.is_multiline && lit.ends_with(triple_quote) {
		return error(@MOD + '.' + @STRUCT + '.' + @FN +
			' string values like "$lit" has unbalanced quote literals `q.quote` in ...${c.excerpt(q.pos)}...')
	}
	c.check_quoted_escapes(q) ?
	c.check_utf8_validity(q) ?
}

// check_quoted_escapes returns an error for any disallowed escape sequences.
// Delimiters in TOML has significant meaning:
// '/''' delimits *literal* strings (WYSIWYG / What-you-see-is-what-you-get)
// "/""" delimits *basic* strings
// Allowed escapes in *basic* strings are:
// \b         - backspace       (U+0008)
// \t         - tab             (U+0009)
// \n         - linefeed        (U+000A)
// \f         - form feed       (U+000C)
// \r         - carriage return (U+000D)
// \"         - quote           (U+0022)
// \\         - backslash       (U+005C)
// \uXXXX     - Unicode         (U+XXXX)
// \UXXXXXXXX - Unicode         (U+XXXXXXXX)
fn (c Checker) check_quoted_escapes(q ast.Quoted) ? {
	// Setup a scanner in stack memory for easier navigation.
	mut s := scanner.new_simple(q.text) ?

	// See https://toml.io/en/v1.0.0#string for more info on string types.
	is_basic := q.quote == `\"`
	for {
		ch := s.next()
		if ch == -1 {
			break
		}
		ch_byte := byte(ch)
		if ch == `\\` {
			next_ch := byte(s.at())

			if next_ch == `\\` {
				s.next()
				continue
			}

			escape := ch_byte.ascii_str() + next_ch.ascii_str()
			if is_basic {
				if q.is_multiline {
					if next_ch == byte(32) && s.peek(1) == byte(92) {
						st := s.state()
						return error(@MOD + '.' + @STRUCT + '.' + @FN +
							' can not escape whitespaces before escapes in multi-line strings (`\\ \\`) at `$escape` ($st.line_nr,$st.col) in ...${c.excerpt(q.pos)}...')
					}
					if next_ch in [`\t`, `\n`, ` `] {
						s.next()
						continue
					}
				}
				if next_ch !in checker.allowed_basic_escape_chars {
					st := s.state()
					return error(@MOD + '.' + @STRUCT + '.' + @FN +
						' unknown basic string escape character `$next_ch.ascii_str()` in `$escape` ($st.line_nr,$st.col) in ...${c.excerpt(q.pos)}...')
				}
			}
			// Check Unicode escapes
			if is_basic && escape.to_lower() == '\\u' {
				// Long type Unicode (\UXXXXXXXX) is a maximum of 10 chars: '\' + 'U' + 8 hex characters
				// we pass in 10 characters from the `u`/`U` which is the longest possible sequence
				// of 9 chars plus one extra.
				if s.remaining() >= 10 {
					pos := s.state().pos
					c.check_unicode_escape(s.text[pos..pos + 11]) or {
						st := s.state()
						return error(@MOD + '.' + @STRUCT + '.' + @FN +
							' escaped Unicode is invalid. $err.msg.capitalize() ($st.line_nr,$st.col) in ...${c.excerpt(q.pos)}...')
					}
				} else {
					pos := s.state().pos
					c.check_unicode_escape(s.text[pos..]) or {
						st := s.state()
						return error(@MOD + '.' + @STRUCT + '.' + @FN +
							' escaped Unicode is invalid. $err.msg.capitalize() ($st.line_nr,$st.col) in ...${c.excerpt(q.pos)}...')
					}
				}
			}
		}
	}
}

// check_utf8_string returns an error if `str` is not valid UTF-8.
fn (c Checker) check_utf8_validity(q ast.Quoted) ? {
	lit := q.text
	if !utf8.validate_str(lit) {
		return error(@MOD + '.' + @STRUCT + '.' + @FN +
			' the string value "$lit" is not valid UTF-8 in ...${c.excerpt(q.pos)}...')
	}
}

// hex2int returns the value of `hex` as `int`.
// NOTE that the code assumes `hex` to be in uppercase A-F.
// It does not work if the length of the input string is beyond the max value of `int`.
// Also and there is no error trapping for illegal hex characters.
fn hex2int(hex string) int {
	// Adapted from https://stackoverflow.com/a/130552/1904615
	mut val := 0
	for i := 0; i < hex.len; i++ {
		if hex[i] <= 57 {
			val += (hex[i] - 48) * (1 << (4 * (hex.len - 1 - i)))
		} else {
			val += (hex[i] - 55) * (1 << (4 * (hex.len - 1 - i)))
		}
	}
	return val
}

// validate_utf8_codepoint_string returns an error if `str` is not a valid Unicode code point.
// `str` is expected to be a `string` containing *only* hex values.
// Any preludes or prefixes like `0x` could pontentially yield wrong results.
fn validate_utf8_codepoint_string(str string) ? {
	int_val := hex2int(str)
	if int_val > checker.utf8_max || int_val < 0 {
		return error('Unicode code point `$str` is outside the valid Unicode scalar value ranges.')
	}
	// Check if the Unicode value is actually in the valid Unicode scalar value ranges.
	// TODO should probably be transferred / implemented in `utf8.validate(...)` also?
	if !((int_val >= 0x0000 && int_val <= 0xD7FF) || (int_val >= 0xE000 && int_val <= 0x10FFFF)) {
		return error('Unicode code point `$str` is not a valid Unicode scalar value.')
	}
	bytes := str.bytes()
	if !utf8.validate(bytes.data, bytes.len) {
		return error('Unicode code point `$str` is not a valid UTF-8 code point.')
	}
}

// check_unicode_escape returns an error if `esc_unicode` is not
// a valid Unicode escape sequence. `esc_unicode` is expected to be
// prefixed with either `u` or `U`.
fn (c Checker) check_unicode_escape(esc_unicode string) ? {
	if esc_unicode.len < 5 || !esc_unicode.to_lower().starts_with('u') {
		// Makes sure the input to this function is actually valid.
		return error('`$esc_unicode` is not a valid escaped Unicode sequence.')
	}
	is_long_esc_type := esc_unicode.starts_with('U')
	mut sequence := esc_unicode[1..]
	hex_digits_len := if is_long_esc_type { 8 } else { 4 }
	if sequence.len < hex_digits_len {
		return error('Unicode escape sequence `$esc_unicode` should be at least $hex_digits_len in length.')
	}
	sequence = sequence[..hex_digits_len]
	// TODO not enforced in BurnSushi testsuite??
	// if !sequence.is_upper() {
	//	return error('Unicode escape sequence `$esc_unicode` is not in all uppercase.')
	//}
	validate_utf8_codepoint_string(sequence.to_upper()) ?
	if is_long_esc_type {
		// Long escape type checks
	} else {
		// Short escape type checks
	}
}

// check_comment returns an error if the contents of `comment` isn't
// a valid TOML comment.
pub fn (c Checker) check_comment(comment ast.Comment) ? {
	lit := comment.text
	// Setup a scanner in stack memory for easier navigation.
	mut s := scanner.new_simple(lit) ?
	for {
		ch := s.next()
		if ch == -1 {
			break
		}
		ch_byte := byte(ch)
		// Check for control characters (allow TAB)
		if util.is_illegal_ascii_control_character(ch_byte) {
			st := s.state()
			return error(@MOD + '.' + @STRUCT + '.' + @FN +
				' control character `$ch_byte.hex()` is not allowed ($st.line_nr,$st.col) "${byte(s.at()).ascii_str()}" near ...${s.excerpt(st.pos, 10)}...')
		}
	}

	// Check for bad UTF-8 encoding
	if !utf8.validate_str(lit) {
		return error(@MOD + '.' + @STRUCT + '.' + @FN +
			' comment "$lit" is not valid UTF-8 in ...${c.excerpt(comment.pos)}...')
	}
}
