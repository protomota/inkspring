#ifndef INKSPRING_CMARK_H
#define INKSPRING_CMARK_H

#include <stddef.h>

typedef struct cmark_node cmark_node;
typedef struct cmark_parser cmark_parser;
typedef struct cmark_syntax_extension cmark_syntax_extension;

void cmark_gfm_core_extensions_ensure_registered(void);
cmark_syntax_extension *cmark_find_syntax_extension(const char *name);
int cmark_parser_attach_syntax_extension(cmark_parser *parser, cmark_syntax_extension *extension);
cmark_parser *cmark_parser_new(int options);
void cmark_parser_feed(cmark_parser *parser, const char *buffer, size_t len);
cmark_node *cmark_parser_finish(cmark_parser *parser);
void cmark_parser_free(cmark_parser *parser);
void cmark_node_free(cmark_node *node);
cmark_node *cmark_node_first_child(cmark_node *node);
cmark_node *cmark_node_next(cmark_node *node);
const char *cmark_node_get_type_string(cmark_node *node);
const char *cmark_node_get_literal(cmark_node *node);
const char *cmark_node_get_url(cmark_node *node);
const char *cmark_node_get_fence_info(cmark_node *node);
int cmark_node_get_heading_level(cmark_node *node);
int cmark_node_get_list_type(cmark_node *node);
int cmark_node_get_list_start(cmark_node *node);

#endif
