#include "api.h"

// ── Grammar declarations ──
extern const TSLanguage *tree_sitter_swift(void);
extern const TSLanguage *tree_sitter_python(void);
extern const TSLanguage *tree_sitter_javascript(void);
extern const TSLanguage *tree_sitter_ruby(void);
extern const TSLanguage *tree_sitter_rust(void);
extern const TSLanguage *tree_sitter_go(void);
extern const TSLanguage *tree_sitter_html(void);
extern const TSLanguage *tree_sitter_css(void);
extern const TSLanguage *tree_sitter_json(void);
extern const TSLanguage *tree_sitter_bash(void);
extern const TSLanguage *tree_sitter_c(void);
extern const TSLanguage *tree_sitter_php(void);
extern const TSLanguage *tree_sitter_markdown(void);
extern const TSLanguage *tree_sitter_markdown_inline(void);

// ── Opaque wrappers for Swift interop ──
// Swift can't import incomplete C types like TSLanguage, TSParser, TSTree.
// These wrappers use void* so Swift sees clean OpaquePointer values.

void *ts_bridge_parser_new(void) {
    return (void *)ts_parser_new();
}

void ts_bridge_parser_delete(void *parser) {
    ts_parser_delete((TSParser *)parser);
}

bool ts_bridge_parser_set_language(void *parser, void *language) {
    return ts_parser_set_language((TSParser *)parser, (const TSLanguage *)language);
}

void *ts_bridge_parser_parse_string(void *parser, const void *old_tree, const char *string, uint32_t length) {
    return (void *)ts_parser_parse_string((TSParser *)parser, (const TSTree *)old_tree, string, length);
}

void ts_bridge_tree_delete(void *tree) {
    ts_tree_delete((TSTree *)tree);
}

void *ts_bridge_tree_root_node(void *tree) {
    TSNode *node = malloc(sizeof(TSNode));
    *node = ts_tree_root_node((const TSTree *)tree);
    return (void *)node;
}

void ts_bridge_node_free(void *node) {
    free(node);
}

uint32_t ts_bridge_node_child_count(void *node) {
    return ts_node_child_count(*(TSNode *)node);
}

void *ts_bridge_node_child(void *node, uint32_t index) {
    TSNode *child = malloc(sizeof(TSNode));
    *child = ts_node_child(*(TSNode *)node, index);
    return (void *)child;
}

const char *ts_bridge_node_type(void *node) {
    return ts_node_type(*(TSNode *)node);
}

uint32_t ts_bridge_node_start_byte(void *node) {
    return ts_node_start_byte(*(TSNode *)node);
}

uint32_t ts_bridge_node_end_byte(void *node) {
    return ts_node_end_byte(*(TSNode *)node);
}

// ── Query wrappers ──

void *ts_bridge_query_new(void *language, const char *source, uint32_t source_len,
                           uint32_t *error_offset, uint32_t *error_type) {
    return (void *)ts_query_new((const TSLanguage *)language, source, source_len,
                                error_offset, (TSQueryError *)error_type);
}

void ts_bridge_query_delete(void *query) {
    ts_query_delete((TSQuery *)query);
}

uint32_t ts_bridge_query_capture_count(void *query) {
    return ts_query_capture_count((const TSQuery *)query);
}

void *ts_bridge_query_cursor_new(void) {
    return (void *)ts_query_cursor_new();
}

void ts_bridge_query_cursor_delete(void *cursor) {
    ts_query_cursor_delete((TSQueryCursor *)cursor);
}

void ts_bridge_query_cursor_exec(void *cursor, void *query, void *node) {
    ts_query_cursor_exec((TSQueryCursor *)cursor, (const TSQuery *)query, *(TSNode *)node);
}

bool ts_bridge_query_cursor_next_capture(void *cursor, uint32_t *match_id_out,
                                          uint32_t *capture_index_out, void **node_out) {
    TSQueryMatch match;
    uint32_t capture_index;
    if (!ts_query_cursor_next_capture((TSQueryCursor *)cursor, &match, &capture_index)) {
        return false;
    }
    *match_id_out = match.id;
    *capture_index_out = match.captures[capture_index].index; // global capture ID
    TSNode *node = malloc(sizeof(TSNode));
    *node = match.captures[capture_index].node;
    *node_out = (void *)node;
    return true;
}

const char *ts_bridge_query_capture_name_for_id(void *query, uint32_t capture_id,
                                                  uint32_t *length) {
    return ts_query_capture_name_for_id((const TSQuery *)query, capture_id, length);
}

// ── Language wrappers ──

void *ts_bridge_language_swift(void)          { return (void *)tree_sitter_swift(); }
void *ts_bridge_language_python(void)         { return (void *)tree_sitter_python(); }
void *ts_bridge_language_javascript(void)     { return (void *)tree_sitter_javascript(); }
void *ts_bridge_language_ruby(void)           { return (void *)tree_sitter_ruby(); }
void *ts_bridge_language_rust(void)           { return (void *)tree_sitter_rust(); }
void *ts_bridge_language_go(void)             { return (void *)tree_sitter_go(); }
void *ts_bridge_language_html(void)           { return (void *)tree_sitter_html(); }
void *ts_bridge_language_css(void)            { return (void *)tree_sitter_css(); }
void *ts_bridge_language_json(void)           { return (void *)tree_sitter_json(); }
void *ts_bridge_language_bash(void)           { return (void *)tree_sitter_bash(); }
void *ts_bridge_language_c(void)              { return (void *)tree_sitter_c(); }
void *ts_bridge_language_php(void)            { return (void *)tree_sitter_php(); }
void *ts_bridge_language_markdown(void)       { return (void *)tree_sitter_markdown(); }
void *ts_bridge_language_markdown_inline(void){ return (void *)tree_sitter_markdown_inline(); }