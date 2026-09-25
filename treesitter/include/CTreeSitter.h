#pragma once
#include "api.h"

// ── Opaque bridge for Swift interop ──
// Swift can't import incomplete C types. Use void* throughout.

void *ts_bridge_parser_new(void);
void  ts_bridge_parser_delete(void *parser);
bool  ts_bridge_parser_set_language(void *parser, void *language);
void *ts_bridge_parser_parse_string(void *parser, const void *old_tree,
                                     const char *string, uint32_t length);
void  ts_bridge_tree_delete(void *tree);
void *ts_bridge_tree_root_node(void *tree);
void  ts_bridge_node_free(void *node);
uint32_t   ts_bridge_node_child_count(void *node);
void      *ts_bridge_node_child(void *node, uint32_t index);
const char *ts_bridge_node_type(void *node);
uint32_t    ts_bridge_node_start_byte(void *node);
uint32_t    ts_bridge_node_end_byte(void *node);

// Query engine
void *ts_bridge_query_new(void *language, const char *source, uint32_t source_len,
                           uint32_t *error_offset, uint32_t *error_type);
void  ts_bridge_query_delete(void *query);
uint32_t ts_bridge_query_capture_count(void *query);
void *ts_bridge_query_cursor_new(void);
void  ts_bridge_query_cursor_delete(void *cursor);
void  ts_bridge_query_cursor_exec(void *cursor, void *query, void *node);
bool  ts_bridge_query_cursor_next_capture(void *cursor, uint32_t *match_id_out,
                                           uint32_t *capture_index_out, void **node_out);
const char *ts_bridge_query_capture_name_for_id(void *query, uint32_t capture_id,
                                                  uint32_t *length);

// Language grammars
void *ts_bridge_language_swift(void);
void *ts_bridge_language_python(void);
void *ts_bridge_language_javascript(void);
void *ts_bridge_language_ruby(void);
void *ts_bridge_language_rust(void);
void *ts_bridge_language_go(void);
void *ts_bridge_language_html(void);
void *ts_bridge_language_css(void);
void *ts_bridge_language_json(void);
void *ts_bridge_language_bash(void);
void *ts_bridge_language_c(void);
void *ts_bridge_language_php(void);
void *ts_bridge_language_markdown(void);
void *ts_bridge_language_markdown_inline(void);