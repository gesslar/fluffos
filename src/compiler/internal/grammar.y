/* This is to make emacs edit this in C mode: -*-C-*- */

/* TODO(sunyc): use %locations to eanble location tracking, for better error. */
/* TODO(sunyc): use %define api.pure full to enable re-entrant parser. */

%define lr.type ielr
%define parse.error detailed
%define parse.assert true
%define parse.lac full

%{
#include "base/std.h"

#include "compiler/internal/grammar_rules.h"
#include "vm/vm.h"
#include "vm/internal/base/machine.h"
#include "compiler/internal/compiler.h"
#include "compiler/internal/lex.h"
#include "compiler/internal/scratchpad.h"
#include "compiler/internal/generate.h"

extern char *outp;

/*
 * This is the grammar definition of LPC, and its parse tree generator.
 */

/* down to one global :)
   bits:
      SWITCH_CONTEXT     - we're inside a switch
      LOOP_CONTEXT       - we're inside a loop
      SWITCH_STRINGS     - a string case has been found
      SWITCH_NUMBERS     - a non-zero numeric case has been found
      SWITCH_RANGES      - a range has been found
      SWITCH_DEFAULT     - a default has been found
 */
int context;
int num_refs;
int func_present;
/*
 * bison & yacc don't prototype this in y.tab.h
 */
int yyparse (void);

%}

/*
 * Token definitions.
 *
 * Appearing in the precedence declarations are:
 *      '+'  '-'  '/'  '*'  '%'
 *      '&'  '|'  '<'  '>'  '^'
 *      '~'  '?'
 *
 * Other single character tokens recognized in this grammar:
 *      '{'  '}'  ','  ';'  ':'
 *      '('  ')'  '['  ']'  '$'
 */
%token L_STRING L_NUMBER L_REAL
%token L_BASIC_TYPE L_TYPE_MODIFIER
%token L_DEFINED_NAME L_IDENTIFIER
%token L_EFUN

%token L_INC L_DEC
%token L_ASSIGN
%token L_LAND L_LOR
%token L_LSH L_RSH
%token L_ORDER
%token L_NOT

%token L_IF L_ELSE
%token L_SWITCH L_CASE L_DEFAULT L_RANGE L_DOT_DOT_DOT
%token L_WHILE L_DO L_FOR L_FOREACH L_IN
%token L_BREAK L_CONTINUE
%token L_RETURN
%token L_ARROW L_DOT L_INHERIT L_COLON_COLON
%token L_ARRAY_OPEN L_MAPPING_OPEN L_FUNCTION_OPEN L_NEW_FUNCTION_OPEN

%token L_SSCANF L_CATCH
%token L_ARRAY
%token L_REF
%token L_DEREF
%token L_PARSE_COMMAND L_TIME_EXPRESSION
%token L_CLASS L_NEW
%token L_PARAMETER

// only in DEBUG
%token L_TREE

// Only ever used in lpcfmt
%token L_PREPROCESSOR_COMMAND

/*
 * 'Dangling else' shift/reduce conflict is well known...
 *  define these precedences to shut yacc up.
 */

%nonassoc LOWER_THAN_ELSE
%nonassoc L_ELSE

/*
 * Operator precedence and associativity...
 * greatly simplify the grammar.
 */

%right L_ASSIGN
%right '?'
%left L_LOR
%left L_LAND
%left '|'
%left '^'
%left '&'
%left L_EQ L_NE
%left L_ORDER '<'
%left L_LSH L_RSH
%left '+' '-'
%left '*' '%' '/'
%right L_NOT '~'
%nonassoc L_INC L_DEC

/*
 * YYTYPE
 *
 * Anything with size > 4 is commented.  Sizes assume typical 64 bit
 * architecture.  This size of the largest element of this union should
 * be kept as small as possible to optimize copying of compiler stack
 * elements.
 */
%union
{
  LPC_INT number; /* 8 */
  LPC_FLOAT real; /* 8 */
  char *string;
  struct argument_t argument;
  ident_hash_elem_t *ihe;
  parse_node_t *node;
  function_context_t *contextp;
  struct {
    parse_node_t *node;
    char num;
  } decl; /* 9 */
  struct {
    uint8_t num_local;
    uint8_t max_num_locals;
    uint16_t context;
    uint16_t save_current_type;
    uint16_t save_exact_types;
  } func_block; /* 8 */
}


/*
 * Type declarations.
 */

/* These hold opcodes */
%type <number> efun_override L_ASSIGN L_ORDER

/* Holds a variable index */
%type <number> L_PARAMETER single_new_local_def

/* These hold arbitrary numbers */
%type <number> L_NUMBER

/* These hold number constant, currently only used for switch cases.*/
%type <number> constant

/* These hold a real number */
%type <real>   L_REAL

/* holds a string constant */
%type <string> L_STRING string_con1 string_con2

/* Holds the number of elements in a list and whether it must be a prototype */
%type <argument> argument_list argument

/* These hold a list of possible interpretations of an identifier */
%type <ihe> L_DEFINED_NAME

/* These hold a type */
%type <number> type optional_star type_modifier_list
%type <number> opt_basic_type L_TYPE_MODIFIER L_BASIC_TYPE basic_type atomic_type
%type <number> cast arg_type
%type <number> opt_atomic_type

/* This holds compressed and less flexible def_name information */
%type <number> L_NEW_FUNCTION_OPEN l_new_function_open

/* holds an identifier or some sort */
%type <string> L_IDENTIFIER L_EFUN function_name identifier
%type <string> new_local_name

/* The following return a parse node */
%type <node> optional_default_arg_value
%type <node> number real string expr0 comma_expr for_expr sscanf catch
%type <node> parse_command time_expression expr_list expr_list2 expr_list3
%type <node> expr_list4 assoc_pair expr4 lvalue function_call lvalue_list
%type <node> new_local_def statement while cond do switch case
%type <node> return optional_else_part block_or_semi
%type <node> case_label statements switch_block
%type <node> expr_list_node expr_or_block
%type <node> single_new_local_def_with_init
%type <node> class_init opt_class_init all def function
%type <node> program modifier_change inheritance type_decl
%type <node> tree

/* The following hold information about blocks and local vars */
%type <decl> local_declarations local_name_list block decl_block
%type <decl> foreach_var foreach_vars first_for_expr foreach for

/* This holds a flag */
%type <number> new_arg

%%

all:
  program { rule_program($$); }
;

program:
  program def possible_semi_colon { CREATE_TWO_VALUES($$, 0, $1, $2); }
  | /* empty */  %empty { $$ = 0; }
;

possible_semi_colon: %empty
  /* empty */
  | ';' { yywarn("Extra ';'. Ignored."); }
;

inheritance:
  type_modifier_list L_INHERIT string_con1 ';' { if (rule_inheritence(&$$, $1, $3)) { YYACCEPT; } }
;

real:
  L_REAL { CREATE_REAL($$, $1); }
;

number:
  L_NUMBER { CREATE_NUMBER($$, $1); }
;

optional_star:
  /* empty */    %empty { $$ = 0; }
  |   '*'       { $$ = TYPE_MOD_ARRAY; }
;

block_or_semi:
  block
          {
            $$ = $1.node;
            if (!$$) {
              CREATE_RETURN($$, 0);
            }
          }
  |   ';' { $$ = 0; }
  | error { $$ = 0; }
;

identifier:
  L_DEFINED_NAME                  { $$ = scratch_copy($1->name); }
  |  L_IDENTIFIER
;

function:
  type optional_star identifier   { $type = rule_func_type($type, $optional_star, $identifier); }
    '(' argument ')'              { $<number>$ = rule_func_proto($type, $optional_star, &$identifier, $argument); }
      block_or_semi               { rule_func(&$$, $type, $optional_star, $identifier, $argument, &$<number>8, &$block_or_semi); }


def:
  function
  |   type name_list ';'
                                  {
                                    if (!($1 & ~(DECL_MODS)) && (pragmas & PRAGMA_STRICT_TYPES))
                                      yyerror("Missing type for global variable declaration");
                                    $$ = 0;
                                  }
  |   inheritance
  |   type_decl
  |   modifier_change
;

modifier_change:
  type_modifier_list ':'
                                  {
                                    if (!$1)
                                      yyerror("modifier list may not be empty.");

                                    if ($1 & FUNC_VARARGS) {
                                      yyerror("Illegal modifier 'varargs' in global modifier list.");
                                      $1 &= ~FUNC_VARARGS;
                                    }

                                    if (!($1 & DECL_ACCESS)) $1 |= DECL_PUBLIC;
                                    global_modifiers = $1;
                                    $$ = 0;
                                  }
;

member_name:
  optional_star identifier
                                  {
                                    /* At this point, the current_type here is only a basic_type */
                                    /* and cannot be unused yet - Sym */

                                    if (current_type == TYPE_VOID)
                                      yyerror("Illegal to declare class member of type void.");
                                    add_local_name($2, current_type | $1);
                                    scratch_free($2);
                                  }
;

member_name_list:
  member_name
  |   member_name ',' member_name_list
;

member_list: %empty
  /* empty */
  | member_list basic_type { current_type = $2; }
      member_name_list ';'
;

type_decl:
  type_modifier_list L_CLASS identifier '{'  { $<ihe>2 = rule_define_class(&$<number>$, $3); }
    member_list '}'                          { rule_define_class_members($<ihe>2, $<number>5); $$ = 0; }
;

new_local_name:
  L_IDENTIFIER
  | L_DEFINED_NAME
                                            {
                                              if ($1->dn.local_num != -1) {
                                                yyerror("Illegal to redeclare local name '%s'", $1->name);
                                              }
                                              $$ = scratch_copy($1->name);
                                            }
;

atomic_type:
  L_BASIC_TYPE
  | L_CLASS L_DEFINED_NAME
                                            {
                                              if ($2->dn.class_num == -1) {
                                                yyerror("Undefined class '%s'", $2->name);
                                                $$ = TYPE_ANY;
                                              } else {
                                                $$ = $2->dn.class_num | TYPE_MOD_CLASS;
                                              }
                                            }
  | L_CLASS L_IDENTIFIER
                                            {
                                              yyerror("Undefined class '%s'", $2);
                                              $$ = TYPE_ANY;
                                            }
;

opt_atomic_type:
  atomic_type
  | /* empty */  %empty { $$ = TYPE_ANY; }
;

basic_type:
  atomic_type
  | opt_atomic_type L_ARRAY { $$ = $1 | TYPE_MOD_ARRAY; }
;

arg_type:
  basic_type
  | basic_type ref { $$ = $1 | LOCAL_MOD_REF; }
;

optional_default_arg_value:
  %empty { $$ = 0; }
 | ':' L_FUNCTION_OPEN comma_expr ':' ')' {
    if (CONFIG_INT(__RC_WOMBLES__)) {
        if(*(outp-2) != ':') {
          yyerror("End of functional not found");
        }
    }
    if (current_function_context->num_locals)
        yyerror("Illegal to use local variable in functional.");
    if (current_function_context->values_list->r.expr)
        current_function_context->values_list->r.expr->kind = current_function_context->values_list->kind;

    $$ = new_node();
    $$->kind = NODE_FUNCTION_CONSTRUCTOR;
    $$->type = TYPE_FUNCTION;
    $$->l.expr = $3;
    $$->r.expr = nullptr; // no arguments
    $$->v.number = FP_FUNCTIONAL + 0 /* args */;
}

new_arg:
  arg_type optional_star
                                              {
                                                $$ = $1 | $2;
                                                if ($1 != TYPE_VOID)
                                                  add_local_name("", $1 | $2);
                                              }
  | arg_type optional_star new_local_name optional_default_arg_value
                                              {
                                                if ($1 == TYPE_VOID)
                                                  yyerror("Illegal to declare argument of type void.");
                                                add_local_name($3, $1 | $2, $optional_default_arg_value);
                                                scratch_free($3);
                                                $$ = $1 | $2;
                                              }
  | new_local_name
                                              {
                                                if (exact_types) {
                                                  yyerror("Missing type for argument");
                                                }
                                                add_local_name($1, TYPE_ANY);
                                                scratch_free($1);
                                                $$ = TYPE_ANY;
                                              }
;

argument:
  /* empty */
     %empty {
      $$.num_arg = 0;
      $$.flags = 0;
    }
  |   argument_list
  |   argument_list L_DOT_DOT_DOT
    {
      int x = type_of_locals_ptr[max_num_locals-1];
      int lt = x & ~LOCAL_MODS;

      $$ = $1;
      $$.flags |= ARG_IS_VARARGS;

      if (x & LOCAL_MOD_REF) {
        yyerror("Variable to hold remainder of args may not be a reference");
        x &= ~LOCAL_MOD_REF;
      }
      if (lt != TYPE_ANY && !(lt & TYPE_MOD_ARRAY))
        yywarn("Variable to hold remainder of arguments should be an array.");
    }
;

argument_list:
  new_arg
    {
      if (($1 & TYPE_MASK) == TYPE_VOID && !($1 & TYPE_MOD_CLASS)) {
        if ($1 & ~TYPE_MASK)
          yyerror("Illegal to declare argument of type void.");
        $$.num_arg = 0;
      } else {
        $$.num_arg = 1;
      }
      $$.flags = 0;
    }
  | argument_list ',' new_arg
    {
      if (!$$.num_arg)    /* first arg was void w/no name */
        yyerror("argument of type void must be the only argument.");
      if (($3 & TYPE_MASK) == TYPE_VOID && !($3 & TYPE_MOD_CLASS))
        yyerror("Illegal to declare argument of type void.");

      $$ = $1;
      $$.num_arg++;
    }
;

type_modifier_list:
  /* empty */
     %empty {
      $$ = 0;
    }
  | L_TYPE_MODIFIER type_modifier_list
    {
      $$ = $1 | $2;
      int acc_mod = $$ & DECL_ACCESS;
#ifdef SENSIBLE_MODIFIERS
      if (acc_mod & (acc_mod - 1)) {
        char buf[256];
        char *end = EndOf(buf);
        get_type_modifiers(buf, end, acc_mod);
        yyerror("Multiple access modifiers (%s)", buf);
        $$ = DECL_PUBLIC;
      }
#endif
    }
;

type:
  type_modifier_list opt_basic_type
    {
      $$ = ($1 << 16) | $2;
      current_type = $$;
    }
;

cast:
  '(' basic_type optional_star ')'
    {
      $$ = $2 | $3;
    }
;

opt_basic_type:
  basic_type
  | /* empty */
     %empty {
      $$ = TYPE_UNKNOWN;
    }
;

name_list:
  new_name
    | new_name ',' name_list
;

new_name:
  optional_star identifier
    {
      if (current_type & (FUNC_VARARGS << 16)){
        yyerror("Illegal to declare varargs variable.");
        current_type &= ~(FUNC_VARARGS << 16);
      }
      /* Now it is ok to merge the two
       * remember that class_num and varargs was the reason for above
       * Do the merging once only per row of decls
       */

      if (current_type & 0xffff0000){
        current_type = (current_type >> 16) | (current_type & 0xffff);
      }

      current_type |= global_modifiers;

      if (!(current_type & DECL_ACCESS)) current_type |= DECL_PUBLIC;

      if ((current_type & ~DECL_MODS) == TYPE_VOID)
        yyerror("Illegal to declare global variable of type void.");

      define_new_variable($2, current_type | $1);
      scratch_free($2);
    }
  | optional_star identifier L_ASSIGN expr0
    {
      parse_node_t *expr, *newnode;
      int type;

      if (current_type & (FUNC_VARARGS << 16)){
        yyerror("Illegal to declare varargs variable.");
        current_type &= ~(FUNC_VARARGS << 16);
      }

      if (current_type & 0xffff0000){
        current_type = (current_type >> 16) | (current_type & 0xffff);
      }

      current_type |= global_modifiers;

      if (!(current_type & DECL_ACCESS)) current_type |= DECL_PUBLIC;

      if ((current_type & ~DECL_MODS) == TYPE_VOID)
        yyerror("Illegal to declare global variable of type void.");

      if ($3 != F_ASSIGN)
        yyerror("Only '=' is legal in initializers.");

      /* ignore current_type == 0, which gets a missing type error
         later anyway */
      if (current_type) {
        type = (current_type | $1) & ~DECL_MODS;
        if ((current_type & ~DECL_MODS) == TYPE_VOID)
          yyerror("Illegal to declare global variable of type void.");
        if (!compatible_types(type, $4->type)) {
          char buff[256];
          char *end = EndOf(buff);
          char *p;

          p = strput(buff, end, "Type mismatch ");
          p = get_two_types(p, end, type, $4->type);
          p = strput(p, end, " when initializing ");
          p = strput(p, end, $2);
          yyerror(buff);
        }
      } else type = 0;
      $4 = do_promotions($4, type);

      CREATE_BINARY_OP(expr, F_VOID_ASSIGN, 0, $4, 0);
      CREATE_OPCODE_1(expr->r.expr, F_GLOBAL_LVALUE, 0,
          define_new_variable($2, current_type | $1));
      newnode = comp_trees[TREE_INIT];
      CREATE_TWO_VALUES(comp_trees[TREE_INIT], 0,
          newnode, expr);
      scratch_free($2);
    }
;

block:
  '{' local_declarations statements '}'
    {
      if ($2.node && $3) {
        CREATE_STATEMENTS($$.node, $2.node, $3);
      } else $$.node = ($2.node ? $2.node : $3);
      $$.num = $2.num;
    }
;

decl_block: block | for | foreach ;

local_declarations:
  /* empty */
     %empty {
      $$.node = 0;
      $$.num = 0;
    }
  | local_declarations basic_type
    {
      if ($2 == TYPE_VOID)
        yyerror("Illegal to declare local variable of type void.");
      /* can't do this in basic_type b/c local_name_list contains
       * expr0 which contains cast which contains basic_type
       */
      current_type = $2;
    }
  local_name_list ';'
    {
      if ($1.node && $4.node) {
        CREATE_STATEMENTS($$.node, $1.node, $4.node);
      } else $$.node = ($1.node ? $1.node : $4.node);
      $$.num = $1.num + $4.num;
    }
;

new_local_def:
  optional_star new_local_name
    {
      if (current_type & LOCAL_MOD_REF) {
        yyerror("Illegal to declare local variable as reference");
        current_type &= ~LOCAL_MOD_REF;
      }
      add_local_name($2, current_type | $1 | LOCAL_MOD_UNUSED);

      scratch_free($2);
      $$ = 0;
    }
  | optional_star new_local_name L_ASSIGN expr0
    {
      int type = (current_type | $1) & ~DECL_MODS;

      if (current_type & LOCAL_MOD_REF) {
        yyerror("Illegal to declare local variable as reference");
        current_type &= ~LOCAL_MOD_REF;
        type &= ~LOCAL_MOD_REF;
      }

      if ($3 != F_ASSIGN)
        yyerror("Only '=' is allowed in initializers.");
      if (!compatible_types($4->type, type)) {
        char buff[256];
        char *end = EndOf(buff);
        char *p;

        p = strput(buff, end, "Type mismatch ");
        p = get_two_types(p, end, type, $4->type);
        p = strput(p, end, " when initializing ");
        p = strput(p, end, $2);

        yyerror(buff);
      }

      $4 = do_promotions($4, type);

      CREATE_UNARY_OP_1($$, F_VOID_ASSIGN_LOCAL, 0, $4,
          add_local_name($2, current_type | $1 | LOCAL_MOD_UNUSED));
      scratch_free($2);
    }
;

single_new_local_def:
  arg_type optional_star new_local_name
    {
      if ($1 == TYPE_VOID)
        yyerror("Illegal to declare local variable of type void.");

      $$ = add_local_name($3, $1 | $2);
      scratch_free($3);
    }
;

single_new_local_def_with_init:
  single_new_local_def L_ASSIGN expr0
    {
      int type = type_of_locals_ptr[$1];

      if (type & LOCAL_MOD_REF) {
        yyerror("Illegal to declare local variable as reference");
        type_of_locals_ptr[$1] &= ~LOCAL_MOD_REF;
      }
      type &= ~LOCAL_MODS;

      if ($2 != F_ASSIGN)
        yyerror("Only '=' is allowed in initializers.");
      if (!compatible_types($3->type, type)) {
        char buff[256];
        char *end = EndOf(buff);
        char *p;

        p = strput(buff, end, "Type mismatch ");
        p = get_two_types(p, end, type, $3->type);
        p = strput(p, end, " when initializing.");
        yyerror(buff);
      }

      $3 = do_promotions($3, type);

      /* this is an expression */
      CREATE_BINARY_OP($$, F_ASSIGN, 0, $3, 0);
      CREATE_OPCODE_1($$->r.expr, F_LOCAL_LVALUE, 0, $1);
    }
;

local_name_list:
  new_local_def
    {
      $$.node = $1;
      $$.num = 1;
    }
  | new_local_def ',' local_name_list
    {
      if ($1 && $3.node) {
        CREATE_STATEMENTS($$.node, $1, $3.node);
      } else $$.node = ($1 ? $1 : $3.node);
      $$.num = 1 + $3.num;
    }
;

statements:
  /* empty */
     %empty {
      $$ = 0;
    }
  | statement statements
    {
      if ($1 && $2) {
        CREATE_STATEMENTS($$, $1, $2);
      } else $$ = ($1 ? $1 : $2);
    }
  | error ';'
    {
      $$ = 0;
    }
;

statement:
  comma_expr ';'
    {
      $$ = pop_value($1);
#ifdef DEBUG
      {
        parse_node_t *replacement;
        CREATE_STATEMENTS(replacement, $$, 0);
        CREATE_OPCODE(replacement->r.expr, F_BREAK_POINT, 0);
        $$ = replacement;
      }
#endif
    }
  | cond
  | while
  | do
  | switch
  | return
  | decl_block
    {
      $$ = $1.node;
      pop_n_locals($1.num);
    }
  | ';'
    {
      $$ = 0;
    }
  | L_BREAK ';'
    {
      if (context & SPECIAL_CONTEXT) {
        yyerror("Cannot break out of catch { } or time_expression { }");
        $$ = 0;
      } else
        if (context & SWITCH_CONTEXT) {
          CREATE_CONTROL_JUMP($$, CJ_BREAK_SWITCH);
        } else
          if (context & LOOP_CONTEXT) {
            CREATE_CONTROL_JUMP($$, CJ_BREAK);
            if (context & LOOP_FOREACH) {
              parse_node_t *replace;
              CREATE_STATEMENTS(replace, 0, $$);
              CREATE_OPCODE(replace->l.expr, F_EXIT_FOREACH, 0);
              $$ = replace;
            }
          } else {
            yyerror("break statement outside loop");
            $$ = 0;
          }
    }
  | L_CONTINUE ';'
    {
      if (context & SPECIAL_CONTEXT)
        yyerror("Cannot continue out of catch { } or time_expression { }");
      else
        if (!(context & LOOP_CONTEXT))
          yyerror("continue statement outside loop");
      CREATE_CONTROL_JUMP($$, CJ_CONTINUE);
    }
;

while:
  L_WHILE '(' comma_expr ')'
    {
      $<number>1 = context;
      context = LOOP_CONTEXT;
    }
  statement
    {
      CREATE_LOOP($$, 1, $6, 0, optimize_loop_test($3));
      context = $<number>1;
    }
;

do:
  L_DO
    {
      $<number>1 = context;
      context = LOOP_CONTEXT;
    }
  statement L_WHILE '(' comma_expr ')' ';'
    {
      CREATE_LOOP($$, 0, $3, 0, optimize_loop_test($6));
      context = $<number>1;
    }
;

for:
  L_FOR '(' first_for_expr ';' for_expr ';' for_expr ')'
    {
      $3.node = pop_value($3.node);
      $<number>1 = context;
      context = LOOP_CONTEXT;
    }
  statement
    {
      $$.num = $3.num; /* number of declarations (0/1) */

      $7 = pop_value($7);
      if ($7 && IS_NODE($7, NODE_UNARY_OP, F_INC)
          && IS_NODE($7->r.expr, NODE_OPCODE_1, F_LOCAL_LVALUE)) {
        LPC_INT lvar = $7->r.expr->l.number;
        CREATE_OPCODE_1($7, F_LOOP_INCR, 0, lvar);
      }

      CREATE_STATEMENTS($$.node, $3.node, 0);
      CREATE_LOOP($$.node->r.expr, 1, $10, $7, optimize_loop_test($5));

      context = $<number>1;
    }
;

foreach_var:
  L_DEFINED_NAME
    {
      if ($1->dn.local_num != -1) {
        CREATE_OPCODE_1($$.node, F_LOCAL_LVALUE, 0, $1->dn.local_num);
        type_of_locals_ptr[$1->dn.local_num] &= ~LOCAL_MOD_UNUSED;
      } else
        if ($1->dn.global_num != -1) {
          CREATE_OPCODE_1($$.node, F_GLOBAL_LVALUE, 0, $1->dn.global_num);
        } else {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "'");
          p = strput(p, end, $1->name);
          p = strput(p, end, "' is not a local or a global variable.");
          yyerror(buf);
          CREATE_OPCODE_1($$.node, F_GLOBAL_LVALUE, 0, 0);
        }
      $$.num = 0;
    }
  | single_new_local_def
    {
      if (type_of_locals_ptr[$1] & LOCAL_MOD_REF) {
        CREATE_OPCODE_1($$.node, F_REF_LVALUE, 0, $1);
      } else {
        CREATE_OPCODE_1($$.node, F_LOCAL_LVALUE, 0, $1);
        type_of_locals_ptr[$1] &= ~LOCAL_MOD_UNUSED;
      }
      $$.num = 1;
    }
  | L_IDENTIFIER
    {
      char buf[256];
      char *end = EndOf(buf);
      char *p;

      p = strput(buf, end, "'");
      p = strput(p, end, $1);
      p = strput(p, end, "' is not a local or a global variable.");
      yyerror(buf);
      CREATE_OPCODE_1($$.node, F_GLOBAL_LVALUE, 0, 0);
      scratch_free($1);
      $$.num = 0;
    }
;

foreach_vars:
  foreach_var
    {
      CREATE_FOREACH($$.node, $1.node, 0);
      $$.num = $1.num;
    }
  | foreach_var ',' foreach_var
    {
      CREATE_FOREACH($$.node, $1.node, $3.node);
      $$.num = $1.num + $3.num;
      if ($1.node->v.number == F_REF_LVALUE)
        yyerror("Mapping key may not be a reference in foreach()");
    }
;

foreach:
  L_FOREACH '(' foreach_vars L_IN expr0 ')'
    {
      $3.node->v.expr = $5;
      $<number>1 = context;
      context = LOOP_CONTEXT | LOOP_FOREACH;
    }
  statement
    {
      $$.num = $3.num;

      CREATE_STATEMENTS($$.node, $3.node, 0);
      CREATE_LOOP($$.node->r.expr, 2, $8, 0, 0);
      CREATE_OPCODE($$.node->r.expr->r.expr, F_NEXT_FOREACH, 0);

      context = $<number>1;
    }
;

for_expr:
  /* EMPTY */
     %empty {
      $$ = 0;
    }
  | comma_expr
;

first_for_expr:
  for_expr
    {
      $$.node = $1;
      $$.num = 0;
    }
  | single_new_local_def_with_init
    {
      $$.node = $1;
      $$.num = 1;
    }
;

switch:
  L_SWITCH '(' comma_expr ')'
    {
      $<number>1 = context;
      context &= LOOP_CONTEXT;
      context |= SWITCH_CONTEXT;
      $<number>2 = mem_block[A_CASES].current_size;
    }
   '{' local_declarations case switch_block '}'
      {
        parse_node_t *node1, *node2;

        if ($9) {
          CREATE_STATEMENTS(node1, $8, $9);
        } else node1 = $8;

        if (context & SWITCH_STRINGS) {
          NODE_NO_LINE(node2, NODE_SWITCH_STRINGS);
        } else if (context & SWITCH_RANGES) {
          NODE_NO_LINE(node2, NODE_SWITCH_RANGES);
        } else if ((context & SWITCH_NUMBERS) ||
            (context & SWITCH_NOT_EMPTY)) {
          NODE_NO_LINE(node2, NODE_SWITCH_NUMBERS);
        } else {
          // to prevent crashing during the remaining parsing bits
          NODE_NO_LINE(node2, NODE_SWITCH_NUMBERS);

          yyerror("need case statements in switch/case, not just default:"); //just a default case present
        }

        node2->l.expr = $3;
        node2->r.expr = node1;
        prepare_cases(node2, $<number>2);
        context = $<number>1;
        $$ = node2;
        pop_n_locals($7.num);
      }
;

switch_block:
  case switch_block
    {
      if ($2){
        CREATE_STATEMENTS($$, $1, $2);
      } else $$ = $1;
    }
  | statement switch_block
    {
      if ($2){
        CREATE_STATEMENTS($$, $1, $2);
      } else $$ = $1;
    }
  | /* empty */
     %empty {
      $$ = 0;
    }
;

case:
  L_CASE case_label ':'
    {
      $$ = $2;
      $$->v.expr = 0;

      add_to_mem_block(A_CASES, (char *)&($2), sizeof($2));
    }
  | L_CASE case_label L_RANGE case_label ':'
    {
      if ( $2->kind != NODE_CASE_NUMBER
          || $4->kind != NODE_CASE_NUMBER )
        yyerror("String case labels not allowed as range bounds");
      if ($2->r.number > $4->r.number) break;

      context |= SWITCH_RANGES;

      $$ = $2;
      $$->v.expr = $4;

      add_to_mem_block(A_CASES, (char *)&($2), sizeof($2));
    }
  | L_CASE case_label L_RANGE ':'
    {
      if ( $2->kind != NODE_CASE_NUMBER )
        yyerror("String case labels not allowed as range bounds");

      context |= SWITCH_RANGES;

      $$ = $2;
      $$->v.expr = new_node();
      $$->v.expr->kind = NODE_CASE_NUMBER;
      $$->v.expr->r.number = LPC_INT_MAX; //maxint

      add_to_mem_block(A_CASES, (char *)&($2), sizeof($2));
    }
  | L_CASE L_RANGE case_label ':'
    {
      if ( $3->kind != NODE_CASE_NUMBER )
        yyerror("String case labels not allowed as range bounds");

      context |= SWITCH_RANGES;
      $$ = new_node();
      $$->kind = NODE_CASE_NUMBER;
      $$->r.number = LPC_INT_MIN; //maxint +1 wraps to min_int, on all computers i know, just not in the C standard iirc
      $$->v.expr = $3;

      add_to_mem_block(A_CASES, (char *)&($$), sizeof($$));
    }
  |  L_DEFAULT ':'
    {
      if (context & SWITCH_DEFAULT) {
        yyerror("Duplicate default");
        $$ = 0;
        break;
      }
      $$ = new_node();
      $$->kind = NODE_DEFAULT;
      $$->v.expr = 0;
      add_to_mem_block(A_CASES, (char *)&($$), sizeof($$));
      context |= SWITCH_DEFAULT;
    }
;

case_label:
  constant
    {
      if ((context & SWITCH_STRINGS) && $1)
        yyerror("Mixed case label list not allowed");

      if ($1)
        context |= SWITCH_NUMBERS;
      else
        context |= SWITCH_NOT_EMPTY;

      $$ = new_node();
      $$->kind = NODE_CASE_NUMBER;
      $$->r.number = (LPC_INT)$1;
    }
  | string_con1
    {
      POINTER_INT str;
      str = store_prog_string($1);
      scratch_free($1);
      if (context & SWITCH_NUMBERS)
        yyerror("Mixed case label list not allowed");
      context |= SWITCH_STRINGS;
      $$ = new_node();
      $$->kind = NODE_CASE_STRING;
      $$->r.number = (LPC_INT)str;
    }
;

constant:
  constant '|' constant
    {
      $$ = $1 | $3;
    }
  | constant '^' constant
    {
      $$ = $1 ^ $3;
    }
  | constant '&' constant
    {
      $$ = $1 & $3;
    }
  | constant L_EQ constant
    {
      $$ = $1 == $3;
    }
  | constant L_NE constant
    {
      $$ = $1 != $3;
    }
  | constant L_ORDER constant
    {
      switch($2){
        case F_GE: $$ = $1 >= $3; break;
        case F_LE: $$ = $1 <= $3; break;
        case F_GT: $$ = $1 >  $3; break;
      }
    }
  | constant '<' constant
    {
      $$ = $1 < $3;
    }
  | constant L_LSH constant
    {
      $$ = $1 << $3;
    }
  | constant L_RSH constant
    {
      $$ = $1 >> $3;
    }
  | constant '+' constant
    {
      $$ = $1 + $3;
    }
  | constant '-' constant
    {
      $$ = $1 - $3;
    }
  | constant '*' constant
    {
      $$ = $1 * $3;
    }
  | constant '%' constant
    {
      if ($3) $$ = $1 % $3; else yyerror("Modulo by zero");
    }
  | constant '/' constant
    {
      if ($3) $$ = $1 / $3; else yyerror("Division by zero");
    }
  | '(' constant ')'
    {
      $$ = $2;
    }
  | L_NUMBER
    {
      $$ = $1;
    }
  | '-' L_NUMBER
    {
      $$ = -$2;
    }
  | L_NOT L_NUMBER
    {
      $$ = !$2;
    }
  | '~' L_NUMBER
    {
      $$ = ~$2;
    }
;

comma_expr:
  expr0
    {
      $$ = $1;
    }
  | comma_expr ',' expr0
    {
      CREATE_TWO_VALUES($$, $3->type, pop_value($1), $3);
    }
;

ref:
  L_REF
;

deref:
  L_DEREF
;

expr0:
  ref lvalue
    {
      int op;

      if (!(context & ARG_LIST))
        yyerror("ref illegal outside function argument list");
      else
        num_refs++;

      switch ($2->kind) {
        case NODE_PARAMETER_LVALUE:
          op = F_LOCAL_LVALUE;
          break;
        case NODE_TERNARY_OP:
        case NODE_OPCODE_1:
        case NODE_UNARY_OP_1:
        case NODE_BINARY_OP:
          op = $2->v.number;
          if (op > F_RINDEX_LVALUE)
            yyerror("Illegal to make reference to range");
          break;
        default:
          op=0; //0 is harmless, i hope
          yyerror("unknown lvalue kind");
      }
      CREATE_UNARY_OP_1($$, F_MAKE_REF, TYPE_ANY, $2, op);
    }
  | deref expr0  %prec L_NOT
    {
      CREATE_UNARY_OP($$, F_DEREF, TYPE_ANY, $2);
    }
  | lvalue L_ASSIGN expr0
    {
      parse_node_t *l = $1, *r = $3;
      /* set this up here so we can change it below */
      /* assignments are backwards; rhs is evaluated before
         lhs, so put the RIGHT hand side on the LEFT hand
         side of the tree node. */
      CREATE_BINARY_OP($$, $2, r->type, r, l);

      /* allow TYPE_STRING += TYPE_NUMBER | TYPE_OBJECT */
      if (exact_types && !compatible_types(r->type, l->type) &&
          !($2 == F_ADD_EQ && l->type == TYPE_STRING &&
            ((COMP_TYPE(r->type, TYPE_NUMBER)) || r->type == TYPE_OBJECT))) {
        char buf[256];
        char *end = EndOf(buf);
        char *p;
        p = strput(buf, end, "Bad assignment ");
        p = get_two_types(p, end, l->type, r->type);
        p = strput(p, end, ".");
        yyerror(buf);
      }

      if ($2 == F_ASSIGN)
        $$->l.expr = do_promotions(r, l->type);
    }
  | error L_ASSIGN expr0
    {
      yyerror("Illegal LHS");
      CREATE_ERROR($$);
    }
  | expr0 '?' expr0 ':' expr0 %prec '?'
    {
      parse_node_t *p1 = $3, *p2 = $5;

      if (exact_types && !compatible_types2(p1->type, p2->type)) {
        char buf[256];
        char *end = EndOf(buf);
        char *p;

        p = strput(buf, end, "Types in ?: do not match ");
        p = get_two_types(p, end, p1->type, p2->type);
        p = strput(p, end, ".");
        yywarn(buf);
      }

      /* optimize if last expression did F_NOT */
      if (IS_NODE($1, NODE_UNARY_OP, F_NOT)) {
        /* !a ? b : c  --> a ? c : b */
        CREATE_IF($$, $1->r.expr, p2, p1);
      } else {
        CREATE_IF($$, $1, p1, p2);
      }
      $$->type = ((p1->type == p2->type) ? p1->type : TYPE_ANY);
    }
  | expr0 L_LOR expr0
    {
      CREATE_LAND_LOR($$, F_LOR, $1, $3);
      if (IS_NODE($1, NODE_LAND_LOR, F_LOR))
        $1->kind = NODE_BRANCH_LINK;
    }
  | expr0 L_LAND expr0
    {
      CREATE_LAND_LOR($$, F_LAND, $1, $3);
      if (IS_NODE($1, NODE_LAND_LOR, F_LAND))
        $1->kind = NODE_BRANCH_LINK;
    }
  | expr0 '|' expr0
    {
      int t1 = $1->type, t3 = $3->type;

      if (is_boolean($1) && is_boolean($3))
        yywarn("bitwise operation on boolean values.");
      if ((t1 & TYPE_MOD_ARRAY) || (t3 & TYPE_MOD_ARRAY)) {
        if (t1 != t3) {
          if ((t1 != TYPE_ANY) && (t3 != TYPE_ANY) &&
              !(t1 & t3 & TYPE_MOD_ARRAY)) {
            char buf[256];
            char *end = EndOf(buf);
            char *p;

            p = strput(buf, end, "Incompatible types for | ");
            p = get_two_types(p, end, t1, t3);
            p = strput(p, end, ".");
            yyerror(buf);
          }
          t1 = TYPE_ANY | TYPE_MOD_ARRAY;
        }
        CREATE_BINARY_OP($$, F_OR, t1, $1, $3);
      }
      else $$ = binary_int_op($1, $3, F_OR, "|");
    }
  | expr0 '^' expr0
    {
      $$ = binary_int_op($1, $3, F_XOR, "^");
    }
  | expr0 '&' expr0
    {
      int t1 = $1->type, t3 = $3->type;
      if (is_boolean($1) && is_boolean($3))
        yywarn("bitwise operation on boolean values.");
      if ((t1 & TYPE_MOD_ARRAY) || (t3 & TYPE_MOD_ARRAY)) {
        if (t1 != t3) {
          if ((t1 != TYPE_ANY) && (t3 != TYPE_ANY) &&
              !(t1 & t3 & TYPE_MOD_ARRAY)) {
            char buf[256];
            char *end = EndOf(buf);
            char *p;

            p = strput(buf, end, "Incompatible types for & ");
            p = get_two_types(p, end, t1, t3);
            p = strput(p, end, ".");
            yyerror(buf);
          }
          t1 = TYPE_ANY | TYPE_MOD_ARRAY;
        }
        CREATE_BINARY_OP($$, F_AND, t1, $1, $3);
      } else $$ = binary_int_op($1, $3, F_AND, "&");
    }
  | expr0 L_EQ expr0
    {
      if (exact_types && !compatible_types2($1->type, $3->type)){
        char buf[256];
        char *end = EndOf(buf);
        char *p;

        p = strput(buf, end, "== always false because of incompatible types ");
        p = get_two_types(p, end, $1->type, $3->type);
        p = strput(p, end, ".");
        yyerror(buf);
      }
      /* x == 0 -> !x */
      if (IS_NODE($1, NODE_NUMBER, 0)) {
        CREATE_UNARY_OP($$, F_NOT, TYPE_NUMBER, $3);
      } else
        if (IS_NODE($3, NODE_NUMBER, 0)) {
          CREATE_UNARY_OP($$, F_NOT, TYPE_NUMBER, $1);
        } else {
          CREATE_BINARY_OP($$, F_EQ, TYPE_NUMBER, $1, $3);
        }
    }
  | expr0 L_NE expr0
    {
      if (exact_types && !compatible_types2($1->type, $3->type)){
        char buf[256];
        char *end = EndOf(buf);
        char *p;

        p = strput(buf, end, "!= always true because of incompatible types ");
        p = get_two_types(p, end, $1->type, $3->type);
        p = strput(p, end, ".");
        yyerror(buf);
      }
      CREATE_BINARY_OP($$, F_NE, TYPE_NUMBER, $1, $3);
    }
  | expr0 L_ORDER expr0
    {
      if (exact_types) {
        int t1 = $1->type;
        int t3 = $3->type;

        if (!COMP_TYPE(t1, TYPE_NUMBER)
            && !COMP_TYPE(t1, TYPE_STRING)) {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Bad left argument to '");
          p = strput(p, end, query_instr_name($2));
          p = strput(p, end, "' : \"");
          p = get_type_name(p, end, t1);
          p = strput(p, end, "\"");
          yyerror(buf);
        } else if (!COMP_TYPE(t3, TYPE_NUMBER)
            && !COMP_TYPE(t3, TYPE_STRING)) {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Bad right argument to '");
          p = strput(p, end, query_instr_name($2));
          p = strput(p, end, "' : \"");
          p = get_type_name(p, end, t3);
          p = strput(p, end, "\"");
          yyerror(buf);
        } else if (!compatible_types2(t1,t3)) {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Arguments to ");
          p = strput(p, end, query_instr_name($2));
          p = strput(p, end, " do not have compatible types : ");
          p = get_two_types(p, end, t1, t3);
          yyerror(buf);
        }
      }
      CREATE_BINARY_OP($$, $2, TYPE_NUMBER, $1, $3);
    }
  | expr0 '<' expr0
    {
      if (exact_types) {
        int t1 = $1->type, t3 = $3->type;

        if (!COMP_TYPE(t1, TYPE_NUMBER)
            && !COMP_TYPE(t1, TYPE_STRING)) {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Bad left argument to '<' : \"");
          p = get_type_name(p, end, t1);
          p = strput(p, end, "\"");
          yyerror(buf);
        } else if (!COMP_TYPE(t3, TYPE_NUMBER)
            && !COMP_TYPE(t3, TYPE_STRING)) {
          char buf[200];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Bad right argument to '<' : \"");
          p = get_type_name(p, end, t3);
          p = strput(p, end, "\"");
          yyerror(buf);
        } else if (!compatible_types2(t1,t3)) {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Arguments to < do not have compatible types : ");
          p = get_two_types(p, end, t1, t3);
          yyerror(buf);
        }
      }
      CREATE_BINARY_OP($$, F_LT, TYPE_NUMBER, $1, $3);
    }
  | expr0 L_LSH expr0
    {
      $$ = binary_int_op($1, $3, F_LSH, "<<");
    }
  | expr0 L_RSH expr0
    {
      $$ = binary_int_op($1, $3, F_RSH, ">>");
    }
  | expr0 '+' expr0
    {
      int result_type;

      if (exact_types) {
        int t1 = $1->type, t3 = $3->type;

        if (t1 == t3){
#ifdef CAST_CALL_OTHERS
          if (t1 == TYPE_UNKNOWN){
            yyerror("Bad arguments to '+' (unknown vs unknown)");
            result_type = TYPE_ANY;
          } else
#endif
            result_type = t1;
        }
        else if (t1 == TYPE_ANY) {
          if (t3 == TYPE_FUNCTION) {
            yyerror("Bad right argument to '+' (function)");
            result_type = TYPE_ANY;
          } else result_type = t3;
        } else if (t3 == TYPE_ANY) {
          if (t1 == TYPE_FUNCTION) {
            yyerror("Bad left argument to '+' (function)");
            result_type = TYPE_ANY;
          } else result_type = t1;
        } else {
          switch(t1) {
            case TYPE_OBJECT:
              if(t3 == TYPE_STRING){
                result_type = TYPE_STRING;
              } else goto add_error;
              break;
            case TYPE_STRING:
              {
                if (t3 == TYPE_REAL || t3 == TYPE_NUMBER || t3 == TYPE_OBJECT){
                  result_type = TYPE_STRING;
                } else goto add_error;
                break;
              }
            case TYPE_NUMBER:
              {
                if (t3 == TYPE_REAL || t3 == TYPE_STRING)
                  result_type = t3;
                else goto add_error;
                break;
              }
            case TYPE_REAL:
              {
                if (t3 == TYPE_NUMBER) result_type = TYPE_REAL;
                else if (t3 == TYPE_STRING) result_type = TYPE_STRING;
                else goto add_error;
                break;
              }
            default:
              {
                if (t1 & t3 & TYPE_MOD_ARRAY) {
                  result_type = TYPE_ANY|TYPE_MOD_ARRAY;
                  break;
                }
            add_error:
                {
                  char buf[256];
                  char *end = EndOf(buf);
                  char *p;

                  p = strput(buf, end, "Invalid argument types to '+' ");
                  p = get_two_types(p, end, t1, t3);
                  yyerror(buf);
                  result_type = TYPE_ANY;
                }
              }
          }
        }
      } else
        result_type = TYPE_ANY;

      /* TODO: perhaps we should do (string)+(number) and
       * (number)+(string) constant folding as well.
       *
       * codefor string x = "foo" + 1;
       *
       * 0000: push string 13, number 1
       * 0004: +
       * 0005: (void)assign_local LV0
       */
      switch ($1->kind) {
        case NODE_NUMBER:
          /* 0 + X */
          if ($1->v.number == 0 &&
              ($3->type == TYPE_NUMBER || $3->type == TYPE_REAL)) {
            $$ = $3;
            break;
          }
          if ($3->kind == NODE_NUMBER) {
            $$ = $1;
            $1->v.number += $3->v.number;
            break;
          }
          if ($3->kind == NODE_REAL) {
            $$ = $3;
            $3->v.real += $1->v.number;
            break;
          }
          /* swapping the nodes may help later constant folding */
          if ($3->type != TYPE_STRING && $3->type != TYPE_ANY)
            CREATE_BINARY_OP($$, F_ADD, result_type, $3, $1);
          else
            CREATE_BINARY_OP($$, F_ADD, result_type, $1, $3);
          break;
        case NODE_REAL:
          if ($3->kind == NODE_NUMBER) {
            $$ = $1;
            $1->v.real += $3->v.number;
            break;
          }
          if ($3->kind == NODE_REAL) {
            $$ = $1;
            $1->v.real += $3->v.real;
            break;
          }
          /* swapping the nodes may help later constant folding */
          if ($3->type != TYPE_STRING && $3->type != TYPE_ANY)
            CREATE_BINARY_OP($$, F_ADD, result_type, $3, $1);
          else
            CREATE_BINARY_OP($$, F_ADD, result_type, $1, $3);
          break;
        case NODE_STRING:
          if ($3->kind == NODE_STRING) {
            /* Combine strings */
            LPC_INT n1, n2;
            const char *s1, *s2;
            char *news;
            int l;

            n1 = $1->v.number;
            n2 = $3->v.number;
            s1 = PROG_STRING(n1);
            s2 = PROG_STRING(n2);
            news = (char *)DMALLOC( (l = strlen(s1))+strlen(s2)+1, TAG_COMPILER, "combine string" );
            strcpy(news, s1);
            strcat(news + l, s2);
            /* free old strings (ordering may help shrink table) */
            if (n1 > n2) {
              free_prog_string(n1); free_prog_string(n2);
            } else {
              free_prog_string(n2); free_prog_string(n1);
            }
            $$ = $1;
            $$->v.number = store_prog_string(news);
            FREE(news);
            break;
          }
          /* Yes, this can actually happen for absurd code like:
           * (int)"foo" + 0
           * for which I guess we ought to generate (int)"foo"
           * in order to be consistent.  Then shoot the coder.
           */
          /* FALLTHROUGH */
        default:
          /* X + 0 */
          if (IS_NODE($3, NODE_NUMBER, 0) &&
              ($1->type == TYPE_NUMBER || $1->type == TYPE_REAL)) {
            $$ = $1;
            break;
          }
          CREATE_BINARY_OP($$, F_ADD, result_type, $1, $3);
          break;
      }
    }
  | expr0 '-' expr0
    {
      int result_type;

      if (exact_types) {
        int t1 = $1->type, t3 = $3->type;

        if (t1 == t3){
          switch(t1){
            case TYPE_ANY:
            case TYPE_NUMBER:
            case TYPE_REAL:
              result_type = t1;
              break;
            default:
              if (!(t1 & TYPE_MOD_ARRAY)){
                type_error("Bad argument number 1 to '-'", t1);
                result_type = TYPE_ANY;
              } else result_type = t1;
          }
        } else if (t1 == TYPE_ANY){
          switch(t3){
            case TYPE_REAL:
            case TYPE_NUMBER:
              result_type = t3;
              break;
            default:
              if (!(t3 & TYPE_MOD_ARRAY)){
                type_error("Bad argument number 2 to '-'", t3);
                result_type = TYPE_ANY;
              } else result_type = t3;
          }
        } else if (t3 == TYPE_ANY){
          switch(t1){
            case TYPE_REAL:
            case TYPE_NUMBER:
              result_type = t1;
              break;
            default:
              if (!(t1 & TYPE_MOD_ARRAY)){
                type_error("Bad argument number 1 to '-'", t1);
                result_type = TYPE_ANY;
              } else result_type = t1;
          }
        } else if ((t1 == TYPE_REAL && t3 == TYPE_NUMBER) ||
            (t3 == TYPE_REAL && t1 == TYPE_NUMBER)){
          result_type = TYPE_REAL;
        } else if (t1 & t3 & TYPE_MOD_ARRAY){
          result_type = TYPE_MOD_ARRAY|TYPE_ANY;
        } else {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Invalid types to '-' ");
          p = get_two_types(p, end, t1, t3);
          yyerror(buf);
          result_type = TYPE_ANY;
        }
      } else result_type = TYPE_ANY;

      switch ($1->kind) {
        case NODE_NUMBER:
          if ($1->v.number == 0) {
            CREATE_UNARY_OP($$, F_NEGATE, $3->type, $3);
          } else if ($3->kind == NODE_NUMBER) {
            $$ = $1;
            $1->v.number -= $3->v.number;
          } else if ($3->kind == NODE_REAL) {
            $$ = $3;
            $3->v.real = $1->v.number - $3->v.real;
          } else {
            CREATE_BINARY_OP($$, F_SUBTRACT, result_type, $1, $3);
          }
          break;
        case NODE_REAL:
          if ($3->kind == NODE_NUMBER) {
            $$ = $1;
            $1->v.real -= $3->v.number;
          } else if ($3->kind == NODE_REAL) {
            $$ = $1;
            $1->v.real -= $3->v.real;
          } else {
            CREATE_BINARY_OP($$, F_SUBTRACT, result_type, $1, $3);
          }
          break;
        default:
          /* optimize X-0 */
          if (IS_NODE($3, NODE_NUMBER, 0)) {
            $$ = $1;
          }
          CREATE_BINARY_OP($$, F_SUBTRACT, result_type, $1, $3);
      }
    }
  |   expr0 '*' expr0
    {
      int result_type;

      if (exact_types){
        int t1 = $1->type, t3 = $3->type;

        if (t1 == t3){
          switch(t1){
            case TYPE_MAPPING:
            case TYPE_ANY:
            case TYPE_NUMBER:
            case TYPE_REAL:
              result_type = t1;
              break;
            default:
              type_error("Bad argument number 1 to '*'", t1);
              result_type = TYPE_ANY;
          }
        } else if (t1 == TYPE_ANY || t3 == TYPE_ANY){
          int t = (t1 == TYPE_ANY) ? t3 : t1;
          switch(t){
            case TYPE_NUMBER:
            case TYPE_REAL:
            case TYPE_MAPPING:
              result_type = t;
              break;
            default:
              type_error((t1 == TYPE_ANY) ?
                  "Bad argument number 2 to '*'" :
                  "Bad argument number 1 to '*'",
                  t);
              result_type = TYPE_ANY;
          }
        } else if ((t1 == TYPE_NUMBER && t3 == TYPE_REAL) ||
            (t1 == TYPE_REAL && t3 == TYPE_NUMBER)){
          result_type = TYPE_REAL;
        } else {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Invalid types to '*' ");
          p = get_two_types(p, end, t1, t3);
          yyerror(buf);
          result_type = TYPE_ANY;
        }
      } else result_type = TYPE_ANY;

      switch ($1->kind) {
        case NODE_NUMBER:
          if ($3->kind == NODE_NUMBER) {
            $$ = $1;
            $$->v.number *= $3->v.number;
            break;
          }
          if ($3->kind == NODE_REAL) {
            $$ = $3;
            $3->v.real *= $1->v.number;
            break;
          }
          CREATE_BINARY_OP($$, F_MULTIPLY, result_type, $3, $1);
          break;
        case NODE_REAL:
          if ($3->kind == NODE_NUMBER) {
            $$ = $1;
            $1->v.real *= $3->v.number;
            break;
          }
          if ($3->kind == NODE_REAL) {
            $$ = $1;
            $1->v.real *= $3->v.real;
            break;
          }
          CREATE_BINARY_OP($$, F_MULTIPLY, result_type, $3, $1);
          break;
        default:
          CREATE_BINARY_OP($$, F_MULTIPLY, result_type, $1, $3);
      }
    }
  | expr0 '%' expr0
    {
      $$ = binary_int_op($1, $3, F_MOD, "%");
    }
  | expr0 '/' expr0
    {
      int result_type;

      if (exact_types){
        int t1 = $1->type, t3 = $3->type;

        if (t1 == t3){
          switch(t1){
            case TYPE_NUMBER:
            case TYPE_REAL:
            case TYPE_ANY:
              result_type = t1;
              break;
            default:
              type_error("Bad argument 1 to '/'", t1);
              result_type = TYPE_ANY;
          }
        } else if (t1 == TYPE_ANY || t3 == TYPE_ANY){
          int t = (t1 == TYPE_ANY) ? t3 : t1;
          if (t == TYPE_REAL || t == TYPE_NUMBER)
            result_type = t;
          else {
            type_error(t1 == TYPE_ANY ?
                "Bad argument 2 to '/'" :
                "Bad argument 1 to '/'", t);
            result_type = TYPE_ANY;
          }
        } else if ((t1 == TYPE_NUMBER && t3 == TYPE_REAL) ||
            (t1 == TYPE_REAL && t3 == TYPE_NUMBER)) {
          result_type = TYPE_REAL;
        } else {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          p = strput(buf, end, "Invalid types to '/' ");
          p = get_two_types(p, end, t1, t3);
          yyerror(buf);
          result_type = TYPE_ANY;
        }
      } else result_type = TYPE_ANY;

      /* constant expressions */
      switch ($1->kind) {
        case NODE_NUMBER:
          if ($3->kind == NODE_NUMBER) {
            if ($3->v.number == 0) {
              yyerror("Divide by zero in constant");
              $$ = $1;
              break;
            }
            $$ = $1;
            $1->v.number /= $3->v.number;
            break;
          }
          if ($3->kind == NODE_REAL) {
            if ($3->v.real == 0.0) {
              yyerror("Divide by zero in constant");
              $$ = $1;
              break;
            }
            $$ = $3;
            $3->v.real = ($1->v.number / $3->v.real);
            break;
          }
          CREATE_BINARY_OP($$, F_DIVIDE, result_type, $1, $3);
          break;
        case NODE_REAL:
          if ($3->kind == NODE_NUMBER) {
            if ($3->v.number == 0) {
              yyerror("Divide by zero in constant");
              $$ = $1;
              break;
            }
            $$ = $1;
            $1->v.real /= $3->v.number;
            break;
          }
          if ($3->kind == NODE_REAL) {
            if ($3->v.real == 0.0) {
              yyerror("Divide by zero in constant");
              $$ = $1;
              break;
            }
            $$ = $1;
            $1->v.real /= $3->v.real;
            break;
          }
          CREATE_BINARY_OP($$, F_DIVIDE, result_type, $1, $3);
          break;
        default:
          CREATE_BINARY_OP($$, F_DIVIDE, result_type, $1, $3);
      }
    }
  | cast expr0  %prec L_NOT
    {
      $$ = $2;
      $$->type = $1;

      if (exact_types &&
          $2->type != $1 &&
          $2->type != TYPE_ANY &&
          $2->type != TYPE_UNKNOWN &&
          $1 != TYPE_VOID) {
        char buf[256];
        char *end = EndOf(buf);
        char *p;

        p = strput(buf, end, "Cannot cast ");
        p = get_type_name(p, end, $2->type);
        p = strput(p, end, "to ");
        p = get_type_name(p, end, $1);
        yyerror(buf);
      }
    }
  | L_INC lvalue  %prec L_NOT  /* note lower precedence here */
    {
      CREATE_UNARY_OP($$, F_PRE_INC, 0, $2);
      if (exact_types){
        switch($2->type){
          case TYPE_NUMBER:
          case TYPE_ANY:
          case TYPE_REAL:
            {
              $$->type = $2->type;
              break;
            }

          default:
            {
              $$->type = TYPE_ANY;
              type_error("Bad argument 1 to ++x", $2->type);
            }
        }
      } else $$->type = TYPE_ANY;
    }
  | L_DEC lvalue  %prec L_NOT  /* note lower precedence here */
    {
      CREATE_UNARY_OP($$, F_PRE_DEC, 0, $2);
      if (exact_types){
        switch($2->type){
          case TYPE_NUMBER:
          case TYPE_ANY:
          case TYPE_REAL:
            {
              $$->type = $2->type;
              break;
            }

          default:
            {
              $$->type = TYPE_ANY;
              type_error("Bad argument 1 to --x", $2->type);
            }
        }
      } else $$->type = TYPE_ANY;

    }
  | L_NOT expr0
    {
      if ($2->kind == NODE_NUMBER) {
        $$ = $2;
        $$->v.number = !($$->v.number);
      } else {
        CREATE_UNARY_OP($$, F_NOT, TYPE_NUMBER, $2);
      }
    }
  | '~' expr0
    {
      if (exact_types && !IS_TYPE($2->type, TYPE_NUMBER))
        type_error("Bad argument to ~", $2->type);
      if ($2->kind == NODE_NUMBER) {
        $$ = $2;
        $$->v.number = ~$$->v.number;
      } else {
        CREATE_UNARY_OP($$, F_COMPL, TYPE_NUMBER, $2);
      }
    }
  | '-' expr0  %prec L_NOT
    {
      int result_type;
      if (exact_types){
        int t = $2->type;
        if (!COMP_TYPE(t, TYPE_NUMBER)){
          type_error("Bad argument to unary '-'", t);
          result_type = TYPE_ANY;
        } else result_type = t;
      } else result_type = TYPE_ANY;

      switch ($2->kind) {
        case NODE_NUMBER:
          $$ = $2;
          $$->v.number = -$$->v.number;
          break;
        case NODE_REAL:
          $$ = $2;
          $$->v.real = -$$->v.real;
          break;
        default:
          CREATE_UNARY_OP($$, F_NEGATE, result_type, $2);
      }
    }
  | lvalue L_INC   /* normal precedence here */
    {
      CREATE_UNARY_OP($$, F_POST_INC, 0, $1);
      $$->v.number = F_POST_INC;
      if (exact_types){
        switch($1->type){
          case TYPE_NUMBER:
          case TYPE_ANY:
          case TYPE_REAL:
            {
              $$->type = $1->type;
              break;
            }

          default:
            {
              $$->type = TYPE_ANY;
              type_error("Bad argument 1 to x++", $1->type);
            }
        }
      } else $$->type = TYPE_ANY;
    }
  | lvalue L_DEC
    {
      CREATE_UNARY_OP($$, F_POST_DEC, 0, $1);
      if (exact_types){
        switch($1->type){
          case TYPE_NUMBER:
          case TYPE_ANY:
          case TYPE_REAL:
            {
              $$->type = $1->type;
              break;
            }

          default:
            {
              $$->type = TYPE_ANY;
              type_error("Bad argument 1 to x--", $1->type);
            }
        }
      } else $$->type = TYPE_ANY;
    }
  | expr4
  | sscanf
  | parse_command
  | time_expression
  | number
  | real
;

return:
  L_RETURN ';'
    {
      if (exact_types && !IS_TYPE(exact_types, TYPE_VOID))
        yywarn("Non-void functions must return a value.");
      CREATE_RETURN($$, 0);
    }
  | L_RETURN comma_expr ';'
    {
      if (exact_types && !compatible_types($2->type, exact_types)) {
        char buf[256];
        char *end = EndOf(buf);
        char *p;

        p = strput(buf, end, "Type of returned value doesn't match function return type ");
        p = get_two_types(p, end, $2->type, exact_types);
        yyerror(buf);
      }
      if (IS_NODE($2, NODE_NUMBER, 0)) {
        CREATE_RETURN($$, 0);
      } else {
        CREATE_RETURN($$, $2);
      }
    }
;

expr_list:
  /* empty */
     %empty {
      CREATE_EXPR_LIST($$, 0);
    }
  | expr_list2
    {
      CREATE_EXPR_LIST($$, $1);
    }
  |   expr_list2 ','
    {
      CREATE_EXPR_LIST($$, $1);
    }
;

expr_list_node:
  expr0
    {
      CREATE_EXPR_NODE($$, $1, 0);
    }
  | expr0 L_DOT_DOT_DOT
    {
      CREATE_EXPR_NODE($$, $1, 1);
    }
;

expr_list2:
  expr_list_node
    {
      $1->kind = 1;
      $$ = $1;
    }
  | expr_list2 ',' expr_list_node
    {
      $3->kind = 0;

      $$ = $1;
      $$->kind++;
      $$->l.expr->r.expr = $3;
      $$->l.expr = $3;
    }
;

expr_list3:
  /* empty */
     %empty {
      /* this is a dummy node */
      CREATE_EXPR_LIST($$, 0);
    }
  | expr_list4
    {
      CREATE_EXPR_LIST($$, $1);
    }
  | expr_list4 ','
    {
      CREATE_EXPR_LIST($$, $1);
    }
;

expr_list4:
  assoc_pair
    {
      $$ = new_node_no_line();
      $$->kind = 2;
      $$->v.expr = $1;
      $$->r.expr = 0;
      $$->type = 0;
      /* we keep track of the end of the chain in the left nodes */
      $$->l.expr = $$;
    }
  | expr_list4 ',' assoc_pair
    {
      parse_node_t *expr;

      expr = new_node_no_line();
      expr->kind = 0;
      expr->v.expr = $3;
      expr->r.expr = 0;
      expr->type = 0;

      $1->l.expr->r.expr = expr;
      $1->l.expr = expr;
      $1->kind += 2;
      $$ = $1;
    }
;

assoc_pair:
  expr0 ':' expr0
    {
      CREATE_TWO_VALUES($$, 0, $1, $3);
    }
;

lvalue:
  expr4
    {
#define LV_ILLEGAL 1
#define LV_RANGE 2
#define LV_INDEX 4
      /* Restrictive lvalues, but I think they make more sense :) */
      $$ = $1;
      if($$->kind == NODE_BINARY_OP && $$->v.number == F_TYPE_CHECK)
        $$ = $$->l.expr;
      switch($$->kind) {
        default:
          yyerror("Illegal lvalue");
          break;
        case NODE_PARAMETER:
          $$->kind = NODE_PARAMETER_LVALUE;
          break;
        case NODE_TERNARY_OP:
          $$->v.number = $$->r.expr->v.number;
        case NODE_OPCODE_1:
        case NODE_UNARY_OP_1:
        case NODE_BINARY_OP:
          if ($$->v.number >= F_LOCAL && $$->v.number <= F_MEMBER)
            $$->v.number++; /* make it an lvalue */
          else if ($$->v.number >= F_INDEX
              && $$->v.number <= F_RE_RANGE) {
            parse_node_t *node = $$;
            int flag = 0;
            do {
              switch(node->kind) {
                case NODE_PARAMETER:
                  node->kind = NODE_PARAMETER_LVALUE;
                  flag |= LV_ILLEGAL;
                  break;
                case NODE_TERNARY_OP:
                  node->v.number = node->r.expr->v.number;
                case NODE_OPCODE_1:
                case NODE_UNARY_OP_1:
                case NODE_BINARY_OP:
                  if(node->kind == NODE_BINARY_OP &&
                      node->v.number == F_TYPE_CHECK) {
                    node = node->l.expr;
                    continue;
                  }

                  if (node->v.number >= F_LOCAL
                      && node->v.number <= F_MEMBER) {
                    node->v.number++;
                    flag |= LV_ILLEGAL;
                    break;
                  } else if (node->v.number == F_INDEX ||
                      node->v.number == F_RINDEX) {
                    node->v.number++;
                    flag |= LV_INDEX;
                    break;
                  } else if (node->v.number >= F_ADD_EQ
                      && node->v.number <= F_ASSIGN) {
                    if (!(flag & LV_INDEX)) {
                      yyerror("Illegal lvalue, a possible lvalue is (x <assign> y)[a]");
                    }
                    if (node->r.expr->kind == NODE_BINARY_OP||
                        node->r.expr->kind == NODE_TERNARY_OP){
                      if (node->r.expr->v.number >= F_NN_RANGE_LVALUE && node->r.expr->v.number <= F_NR_RANGE_LVALUE)
                        yyerror("Illegal to have (x[a..b] <assign> y) to be the beginning of an lvalue");
                    }
                    flag = LV_ILLEGAL;
                    break;
                  } else if (node->v.number >= F_NN_RANGE
                      && node->v.number <= F_RE_RANGE) {
                    if (flag & LV_RANGE) {
                      yyerror("Can't do range lvalue of range lvalue.");
                      flag |= LV_ILLEGAL;
                      break;
                    }
                    if (flag & LV_INDEX){
                      yyerror("Can't do indexed lvalue of range lvalue.");
                      flag |= LV_ILLEGAL;
                      break;
                    }
                    if (node->v.number == F_NE_RANGE) {
                      /* x[foo..] -> x[foo..<1] */
                      parse_node_t *rchild = node->r.expr;
                      node->kind = NODE_TERNARY_OP;
                      CREATE_BINARY_OP(node->r.expr,
                          F_NR_RANGE_LVALUE,
                          0, 0, rchild);
                      CREATE_NUMBER(node->r.expr->l.expr, 1);
                    } else if (node->v.number == F_RE_RANGE) {
                      /* x[<foo..] -> x[<foo..<1] */
                      parse_node_t *rchild = node->r.expr;
                      node->kind = NODE_TERNARY_OP;
                      CREATE_BINARY_OP(node->r.expr,
                          F_RR_RANGE_LVALUE,
                          0, 0, rchild);
                      CREATE_NUMBER(node->r.expr->l.expr, 1);
                    } else
                      node->r.expr->v.number++;
                    flag |= LV_RANGE;
                    node = node->r.expr->r.expr;
                    continue;
                  }
                default:
                  yyerror("Illegal lvalue");
                  flag = LV_ILLEGAL;
                  break;
              }
              if ((flag & LV_ILLEGAL) || !(node = node->r.expr)) break;
            } while (1);
            break;
          } else
            yyerror("Illegal lvalue");
          break;
      }
    }
;

l_new_function_open:
  L_NEW_FUNCTION_OPEN
  | L_FUNCTION_OPEN efun_override
    {
      $$ = ($2 << 8) | FP_EFUN;
    }
;

expr4:
  function_call
  | L_DEFINED_NAME
    {
      int i;
      if ((i = $1->dn.local_num) != -1) {
        type_of_locals_ptr[i] &= ~LOCAL_MOD_UNUSED;
        if (type_of_locals_ptr[i] & LOCAL_MOD_REF)
          CREATE_OPCODE_1($$, F_REF, type_of_locals_ptr[i] & ~LOCAL_MOD_REF,i & 0xff);
        else
          CREATE_OPCODE_1($$, F_LOCAL, type_of_locals_ptr[i], i & 0xff);
        if (current_function_context)
          current_function_context->num_locals++;
      } else
        if ((i = $1->dn.global_num) != -1) {
          if (current_function_context)
            current_function_context->bindable = FP_NOT_BINDABLE;
          CREATE_OPCODE_1($$, F_GLOBAL,
              VAR_TEMP(i)->type & ~DECL_MODS, i);
          if (VAR_TEMP(i)->type & DECL_HIDDEN) {
            char buf[256];
            char *end = EndOf(buf);
            char *p;

            p = strput(buf, end, "Illegal to use private variable '");
            p = strput(p, end, $1->name);
            p = strput(p, end, "'");
            yyerror(buf);
          }
        } else {
          char buf[256];
          char *end = EndOf(buf);
          char *p;

          auto max_local_variables = CFG_INT(__MAX_LOCAL_VARIABLES__);
          p = strput(buf, end, "Undefined variable '");
          p = strput(p, end, $1->name);
          p = strput(p, end, "'");
          if (current_number_of_locals < max_local_variables) {
            add_local_name($1->name, TYPE_ANY);
          }
          CREATE_ERROR($$);
          yyerror(buf);
        }
    }
  | L_IDENTIFIER
    {
      char buf[256];
      char *end = EndOf(buf);
      char *p;

      auto max_local_variables = CFG_INT(__MAX_LOCAL_VARIABLES__);
      p = strput(buf, end, "Undefined variable '");
      p = strput(p, end, $1);
      p = strput(p, end, "'");
      if (current_number_of_locals < max_local_variables) {
        add_local_name($1, TYPE_ANY);
      }
      CREATE_ERROR($$);
      yyerror(buf);
      scratch_free($1);
    }
  | L_PARAMETER
    {
      CREATE_PARAMETER($$, TYPE_ANY, $1);
    }
  | '$' '('
    {
      $<contextp>$ = current_function_context;
      /* already flagged as an error */
      if (current_function_context)
        current_function_context = current_function_context->parent;
    }
  comma_expr ')'
    {
      parse_node_t *node;

      current_function_context = $<contextp>3;

      if (!current_function_context || current_function_context->num_parameters < 0) {
        /* This was illegal, and error'ed when the '$' token
         * was returned.
         */
        CREATE_ERROR($$);
      } else {
        CREATE_OPCODE_1($$, F_LOCAL, $4->type,
            current_function_context->values_list->kind++);

        node = new_node_no_line();
        node->type = 0;
        current_function_context->values_list->l.expr->r.expr = node;
        current_function_context->values_list->l.expr = node;
        node->r.expr = 0;
        node->v.expr = $4;
      }
    }
  | expr4 L_ARROW identifier
    {
      if ($1->type == TYPE_ANY) {
        int cmi;
        unsigned short tp;

        if ((cmi = lookup_any_class_member($3, &tp)) != -1) {
          CREATE_UNARY_OP_1($$, F_MEMBER, tp, $1, 0);
          $$->l.number = cmi;
        } else {
          CREATE_ERROR($$);
        }
      } else if (!IS_CLASS($1->type)) {
        yyerror("Left argument of -> is not a class");
        CREATE_ERROR($$);
      } else {
        CREATE_UNARY_OP_1($$, F_MEMBER, 0, $1, 0);
        $$->l.number = lookup_class_member(CLASS_IDX($1->type),
            $3,
            &($$->type));
      }

      scratch_free($3);
    }
  | expr4 L_DOT identifier
    {
      if ($1->type == TYPE_ANY) {
        int cmi;
        unsigned short tp;

        if ((cmi = lookup_any_class_member($3, &tp)) != -1) {
          CREATE_UNARY_OP_1($$, F_MEMBER, tp, $1, 0);
          $$->l.number = cmi;
        } else {
          CREATE_ERROR($$);
        }
      } else if (!IS_CLASS($1->type)) {
        yyerror("Left argument of . is not a class");
        CREATE_ERROR($$);
      } else {
        CREATE_UNARY_OP_1($$, F_MEMBER, 0, $1, 0);
        $$->l.number = lookup_class_member(CLASS_IDX($1->type),
            $3,
            &($$->type));
      }

      scratch_free($3);
    }
  | expr4 '[' comma_expr L_RANGE comma_expr ']'
    {
    if (!CONFIG_INT(__RC_OLD_RANGE_BEHAVIOR__)) {
      if (CONFIG_INT(__RC_WARN_OLD_RANGE_BEHAVIOR__)) {
      if ($1->type != TYPE_MAPPING &&
          $5->kind == NODE_NUMBER && $5->v.number < 0)
        yywarn("A negative constant as the second element of arr[x..y] no longer means indexing from the end.  Use arr[x..<y]");
      }
    }
      $$ = make_range_node(F_NN_RANGE, $1, $3, $5);
    }
  | expr4 '[' '<' comma_expr L_RANGE comma_expr ']'
    {
      $$ = make_range_node(F_RN_RANGE, $1, $4, $6);
    }
  | expr4 '[' '<' comma_expr L_RANGE '<' comma_expr ']'
    {
      if ($7->kind == NODE_NUMBER && $7->v.number <= 1)
        $$ = make_range_node(F_RE_RANGE, $1, $4, 0);
      else
        $$ = make_range_node(F_RR_RANGE, $1, $4, $7);
    }
  | expr4 '[' comma_expr L_RANGE '<' comma_expr ']'
    {
      if ($6->kind == NODE_NUMBER && $6->v.number <= 1)
        $$ = make_range_node(F_NE_RANGE, $1, $3, 0);
      else
        $$ = make_range_node(F_NR_RANGE, $1, $3, $6);
    }
  | expr4 '[' comma_expr L_RANGE ']'
    {
      $$ = make_range_node(F_NE_RANGE, $1, $3, 0);
    }
  | expr4 '[' '<' comma_expr L_RANGE ']'
    {
      $$ = make_range_node(F_RE_RANGE, $1, $4, 0);
    }
  | expr4 '[' '<' comma_expr ']'
    {
      if (IS_NODE($1, NODE_CALL, F_AGGREGATE)
          && $4->kind == NODE_NUMBER) {
        int i = $4->v.number;
        if (i < 1 || i > $1->l.number)
          yyerror("Illegal index to array constant.");
        else {
          parse_node_t *node = $1->r.expr;
          i = $1->l.number - i;
          while (i--)
            node = node->r.expr;
          $$ = node->v.expr;
          break;
        }
      }
      CREATE_BINARY_OP($$, F_RINDEX, 0, $4, $1);
      if (exact_types) {
        switch($1->type) {
          case TYPE_MAPPING:
            yyerror("Illegal index for mapping.");
          case TYPE_ANY:
            $$->type = TYPE_ANY;
            break;
          case TYPE_STRING:
          case TYPE_BUFFER:
            $$->type = TYPE_NUMBER;
            if (!IS_TYPE($4->type,TYPE_NUMBER))
              type_error("Bad type of index", $4->type);
            break;

          default:
            if ($1->type & TYPE_MOD_ARRAY) {
              $$->type = $1->type & ~TYPE_MOD_ARRAY;
              if ($$->type != TYPE_ANY)
                $$ = add_type_check($$, $$->type);
              if (!IS_TYPE($4->type,TYPE_NUMBER))
                type_error("Bad type of index", $4->type);
            } else {
              type_error("Value indexed has a bad type ", $1->type);
              $$->type = TYPE_ANY;
            }
        }
      } else $$->type = TYPE_ANY;
    }
  | expr4 '[' comma_expr ']'
    {
      /* Something stupid like ({ 1, 2, 3 })[1]; we take the
       * time to optimize this because people who don't understand
       * the preprocessor often write things like:
       *
       * #define MY_ARRAY ({ "foo", "bar", "bazz" })
       * ...
       * ... MY_ARRAY[1] ...
       *
       * which of course expands to the above.
       */
      if (IS_NODE($1, NODE_CALL, F_AGGREGATE) && $3->kind == NODE_NUMBER) {
        int i = $3->v.number;
        if (i < 0 || i >= $1->l.number)
          yyerror("Illegal index to array constant.");
        else {
          parse_node_t *node = $1->r.expr;
          while (i--)
            node = node->r.expr;
          $$ = node->v.expr;
          break;
        }
      }
#ifndef OLD_RANGE_BEHAVIOR
      if ($3->kind == NODE_NUMBER && $3->v.number < 0)
        yywarn("A negative constant in arr[x] no longer means indexing from the end.  Use arr[<x]");
#endif
      CREATE_BINARY_OP($$, F_INDEX, 0, $3, $1);
      if (exact_types) {
        switch($1->type) {
          case TYPE_MAPPING:
          case TYPE_ANY:
            $$->type = TYPE_ANY;
            break;
          case TYPE_STRING:
          case TYPE_BUFFER:
            $$->type = TYPE_NUMBER;
            if (!IS_TYPE($3->type,TYPE_NUMBER))
              type_error("Bad type of index", $3->type);
            break;

          default:
            if ($1->type & TYPE_MOD_ARRAY) {
              $$->type = $1->type & ~TYPE_MOD_ARRAY;
              if($$->type != TYPE_ANY)
                $$ = add_type_check($$, $$->type);
              if (!IS_TYPE($3->type,TYPE_NUMBER))
                type_error("Bad type of index", $3->type);
            } else {
              type_error("Value indexed has a bad type ", $1->type);
              $$->type = TYPE_ANY;
            }
        }
      } else $$->type = TYPE_ANY;
    }
  | string
  | '(' comma_expr ')'
    {
      $$ = $2;
    }
  | catch
  | tree
  | L_BASIC_TYPE
    {
      auto max_local_variables = CFG_INT(__MAX_LOCAL_VARIABLES__);

      if ($1 != TYPE_FUNCTION) yyerror("Reserved type name unexpected.");
      $<func_block>$.num_local = current_number_of_locals;
      $<func_block>$.max_num_locals = max_num_locals;
      $<func_block>$.context = context;
      $<func_block>$.save_current_type = current_type;
      $<func_block>$.save_exact_types = exact_types;
      if (type_of_locals_ptr + max_num_locals + max_local_variables >= &type_of_locals[type_of_locals_size])
        reallocate_locals();
      deactivate_current_locals();
      locals_ptr += current_number_of_locals;
      type_of_locals_ptr += max_num_locals;
      max_num_locals = current_number_of_locals = 0;
      push_function_context();
      current_function_context->num_parameters = -1;
      exact_types = TYPE_ANY;
      context = 0;
    }
  '(' argument ')' block
    {
      if ($4.flags & ARG_IS_VARARGS) {
        yyerror("Anonymous varargs functions aren't implemented");
      }
      if (!$6.node) {
        CREATE_RETURN($6.node, 0);
      } else if ($6.node->kind != NODE_RETURN &&
          ($6.node->kind != NODE_TWO_VALUES || $6.node->r.expr->kind != NODE_RETURN)) {
        parse_node_t *replacement;
        CREATE_STATEMENTS(replacement, $6.node, 0);
        CREATE_RETURN(replacement->r.expr, 0);
        $6.node = replacement;
      }

      $$ = new_node();
      $$->kind = NODE_ANON_FUNC;
      $$->type = TYPE_FUNCTION;
      $$->l.number = (max_num_locals - $4.num_arg);
      $$->r.expr = $6.node;
      $$->v.number = $4.num_arg;
      if (current_function_context->bindable)
        $$->v.number |= 0x10000;
      free_all_local_names(1);

      current_number_of_locals = $<func_block>2.num_local;
      max_num_locals = $<func_block>2.max_num_locals;
      context = $<func_block>2.context;
      current_type = $<func_block>2.save_current_type;
      exact_types = $<func_block>2.save_exact_types;
      pop_function_context();

      locals_ptr -= current_number_of_locals;
      type_of_locals_ptr -= max_num_locals;
      reactivate_current_locals();
    }
  | l_new_function_open ':' ')'
    {
      if (CONFIG_INT(__RC_WOMBLES__)) {
        if(*(outp-2) != ':') {
          yyerror("End of functional not found");
        }
      }
      $$ = new_node();
      $$->kind = NODE_FUNCTION_CONSTRUCTOR;
      $$->type = TYPE_FUNCTION;
      $$->r.expr = 0;
      switch ($1 & 0xff) {
        case FP_L_VAR:
          yyerror("Illegal to use local variable in a functional.");
          CREATE_NUMBER($$->l.expr, 0);
          $$->l.expr->r.expr = 0;
          $$->l.expr->l.expr = 0;
          $$->v.number = FP_FUNCTIONAL;
          break;
        case FP_G_VAR:
          CREATE_OPCODE_1($$->l.expr, F_GLOBAL, 0, $1 >> 8);
          $$->v.number = FP_FUNCTIONAL | FP_NOT_BINDABLE;
          if (VAR_TEMP($$->l.expr->l.number)->type & DECL_HIDDEN) {
            char buf[256];
            char *end = EndOf(buf);
            char *p;

            p = strput(buf, end, "Illegal to use private variable '");
            p = strput(p, end, VAR_TEMP($$->l.expr->l.number)->name);
            p = strput(p, end, "'");
            yyerror(buf);
          }
          break;
        default:
          $$->v.number = $1;
          break;
      }
    }
  | l_new_function_open ',' expr_list2 ':' ')'
    {
      if (CONFIG_INT(__RC_WOMBLES__)) {
        if(*(outp-2) != ':') {
          yyerror("End of functional not found");
        }
      }
      $$ = new_node();
      $$->kind = NODE_FUNCTION_CONSTRUCTOR;
      $$->type = TYPE_FUNCTION;
      $$->v.number = $1;
      $$->r.expr = $3;

      switch ($1 & 0xff) {
        case FP_EFUN: {
                        int *argp;
                        int f = $1 >>8;
                        int num = $3->kind;
                        int max_arg = predefs[f].max_args;
                        if(f!=-1){
                          if (num > max_arg && max_arg != -1) {
                            parse_node_t *pn = $3;

                            while (pn) {
                              if (pn->type & 1) break;
                              pn = pn->r.expr;
                            }

                            if (!pn) {
                              char bff[256];
                              char *end = EndOf(bff);
                              char *p;

                              p = strput(bff, end, "Too many arguments to ");
                              p = strput(p, end, predefs[f].word);
                              yyerror(bff);
                            }
                          } else if (max_arg != -1 && exact_types) {
                            /*
                             * Now check all types of arguments to efuns.
                             */
                            int i, argn, tmp;
                            parse_node_t *enode = $3;
                            argp = &efun_arg_types[predefs[f].arg_index];

                            for (argn = 0; argn < num; argn++) {
                              if (enode->type & 1) break;

                              tmp = enode->v.expr->type;
                              for (i=0; !compatible_types(tmp, argp[i])
                                  && argp[i] != 0; i++)
                                ;
                              if (argp[i] == 0) {
                                char buf[256];
                                char *end = EndOf(buf);
                                char *p;

                                p = strput(buf, end, "Bad argument ");
                                p = strput_int(p, end, argn+1);
                                p = strput(p, end, " to efun ");
                                p = strput(p, end, predefs[f].word);
                                p = strput(p, end, "()");
                                yyerror(buf);
                              } else {
                                /* this little section necessary b/c in the
                                   case float | int we dont want to do
                                   promoting. */
                                if (tmp == TYPE_NUMBER && argp[i] == TYPE_REAL) {
                                  for (i++; argp[i] && argp[i] != TYPE_NUMBER; i++)
                                    ;
                                  if (!argp[i])
                                    enode->v.expr = promote_to_float(enode->v.expr);
                                }
                                if (tmp == TYPE_REAL && argp[i] == TYPE_NUMBER) {
                                  for (i++; argp[i] && argp[i] != TYPE_REAL; i++)
                                    ;
                                  if (!argp[i])
                                    enode->v.expr = promote_to_int(enode->v.expr);
                                }
                              }
                              while (argp[i] != 0)
                                i++;
                              argp += i + 1;
                              enode = enode->r.expr;
                            }
                          }
                        }
                        break;
                      }
        case FP_L_VAR:
        case FP_G_VAR:
                      yyerror("Can't give parameters to functional.");
                      break;
      }
    }
  | L_FUNCTION_OPEN comma_expr ':' ')'
    {
      if (CONFIG_INT(__RC_WOMBLES__)) {
        if(*(outp-2) != ':') {
          yyerror("End of functional not found");
        }
      }
      if (current_function_context->num_locals)
        yyerror("Illegal to use local variable in functional.");
      if (current_function_context->values_list->r.expr)
        current_function_context->values_list->r.expr->kind = current_function_context->values_list->kind;

      $$ = new_node();
      $$->kind = NODE_FUNCTION_CONSTRUCTOR;
      $$->type = TYPE_FUNCTION;
      $$->l.expr = $2;
      if ($2->kind == NODE_STRING)
        yywarn("Function pointer returning string constant is NOT a function call");
      $$->r.expr = current_function_context->values_list->r.expr;
      $$->v.number = FP_FUNCTIONAL + current_function_context->bindable
        + (current_function_context->num_parameters << 8);
      pop_function_context();
    }
  | L_MAPPING_OPEN expr_list3 ']' ')'
    {
      if (CONFIG_INT(__RC_WOMBLES__)) {
        if(*(outp-2) != ']') {
          yyerror("End of mapping not found");
        }
      }
      CREATE_CALL($$, F_AGGREGATE_ASSOC, TYPE_MAPPING, $2);
    }
  | L_ARRAY_OPEN expr_list '}' ')'
    {
      if (CONFIG_INT(__RC_WOMBLES__)) {
        if(*(outp-2) != '}') {
          yyerror("End of array not found");
        }
      }
      CREATE_CALL($$, F_AGGREGATE, TYPE_ANY | TYPE_MOD_ARRAY, $2);
    }
;

expr_or_block:
  block
    {
      $$ = $1.node;
    }
  | '(' comma_expr ')'
    {
      $$ = insert_pop_value($2);
    }
;

catch:
  L_CATCH
    {
      $<number>$ = context;
      context = SPECIAL_CONTEXT;
    }
  expr_or_block
    {
      CREATE_CATCH($$, $3);
      context = $<number>2;
    }
  ;

tree:
  L_TREE block
    {
#ifdef DEBUG
      $$ = new_node_no_line();
      lpc_tree_form($2.node, $$);
#endif
    }
  | L_TREE '(' comma_expr ')'
    {
#ifdef DEBUG
      $$ = new_node_no_line();
      lpc_tree_form($3, $$);
#endif
    }
;

sscanf:
  L_SSCANF '(' expr0 ',' expr0 lvalue_list ')'
    {
      int p = $6->v.number;
      CREATE_LVALUE_EFUN($$, TYPE_NUMBER, $6);
      CREATE_BINARY_OP_1($$->l.expr, F_SSCANF, 0, $3, $5, p);
    }
;

parse_command:
  L_PARSE_COMMAND '(' expr0 ',' expr0 ',' expr0 lvalue_list ')'
    {
      int p = $8->v.number;
      CREATE_LVALUE_EFUN($$, TYPE_NUMBER, $8);
      CREATE_TERNARY_OP_1($$->l.expr, F_PARSE_COMMAND, 0,
          $3, $5, $7, p);
    }
;

time_expression:
  L_TIME_EXPRESSION
    {
      $<number>$ = context;
      context = SPECIAL_CONTEXT;
    }
  expr_or_block
    {
      CREATE_TIME_EXPRESSION($$, $3);
      context = $<number>2;
    }
;

lvalue_list:
  /* empty */
     %empty {
      $$ = new_node_no_line();
      $$->r.expr = 0;
      $$->v.number = 0;
    }
  | ',' lvalue lvalue_list
    {
      parse_node_t *insert;

      $$ = $3;
      insert = new_node_no_line();
      insert->r.expr = $3->r.expr;
      insert->l.expr = $2;
      $3->r.expr = insert;
      $$->v.number++;
    }
;

string:
  string_con2
    {
      CREATE_STRING($$, $1);
      scratch_free($1);
    }
;

string_con1:
  string_con2
  | '(' string_con1 ')'
    {
      $$ = $2;
    }
  | string_con1 '+' string_con1
    {
      $$ = scratch_join($1, $3);
    }
;

string_con2:
  L_STRING
  | string_con2 L_STRING
    {
      $$ = scratch_join($1, $2);
    }
;

class_init:
  identifier ':' expr0
    {
      $$ = new_node();
      $$->l.expr = (parse_node_t *)$1;
      $$->v.expr = $3;
      $$->r.expr = 0;
    }
;

opt_class_init:
  /* empty */
     %empty {
      $$ = 0;
    }
  | opt_class_init ',' class_init
    {
      $$ = $3;
      $$->r.expr = $1;
    }
;

function_call:
  efun_override '('
    {
      $<number>$ = context;
      $<number>2 = num_refs;
      context |= ARG_LIST;
    }
  expr_list ')'
    {
      context = $<number>3;
      $$ = validate_efun_call($1,$4);
      $$ = check_refs(num_refs - $<number>2, $4, $$);
      num_refs = $<number>2;
    }
  | L_NEW '('
    {
      $<number>$ = context;
      $<number>2 = num_refs;
      context |= ARG_LIST;
    }
  expr_list ')'
    {
      ident_hash_elem_t *ihe;
      int f;

      context = $<number>3;
      ihe = lookup_ident("clone_object");

      if ((f = ihe->dn.simul_num) != -1) {
        $$ = $4;
        $$->kind = NODE_CALL_1;
        $$->v.number = F_SIMUL_EFUN;
        $$->l.number = f;
        $$->type = (SIMUL(f)->type) & ~DECL_MODS;
      } else {
        $$ = validate_efun_call(lookup_predef("clone_object"), $4);
#ifdef CAST_CALL_OTHERS
        $$->type = TYPE_UNKNOWN;
#else
        $$->type = TYPE_ANY;
#endif
      }
      $$ = check_refs(num_refs - $<number>2, $4, $$);
      num_refs = $<number>2;
    }
  | L_NEW '(' L_CLASS L_DEFINED_NAME opt_class_init ')'
    {
      parse_node_t *node;

      if ($4->dn.class_num == -1) {
        char buf[256];
        char *end = EndOf(buf);
        char *p;

        p = strput(buf, end, "Undefined class '");
        p = strput(p, end, $4->name);
        p = strput(p, end, "'");
        yyerror(buf);
        CREATE_ERROR($$);
        node = $5;
        while (node) {
          scratch_free((char *)node->l.expr);
          node = node->r.expr;
        }
      } else {
        int type = $4->dn.class_num | TYPE_MOD_CLASS;

        if ((node = $5)) {
          CREATE_TWO_VALUES($$, type, 0, 0);
          $$->l.expr = reorder_class_values($4->dn.class_num,
              node);
          CREATE_OPCODE_1($$->r.expr, F_NEW_CLASS,
              type, $4->dn.class_num);

        } else {
          CREATE_OPCODE_1($$, F_NEW_EMPTY_CLASS,
              type, $4->dn.class_num);
        }
      }
    }
  | L_NEW '(' L_CLASS L_IDENTIFIER opt_class_init ')'
    {
      parse_node_t *node;
      char buf[256];
      char *end = EndOf(buf);
      char *p;

      p = strput(buf, end, "Undefined class '");
      p = strput(p, end, $4);
      p = strput(p, end, "'");
      yyerror(buf);
      CREATE_ERROR($$);
      node = $5;
      while (node) {
        scratch_free((char *)node->l.expr);
        node = node->r.expr;
      }
    }
  | L_DEFINED_NAME '('
    {
      $<number>$ = context;
      $<number>2 = num_refs;
      context |= ARG_LIST;
    }
  expr_list ')'
    {
      int f;

      context = $<number>3;
      $$ = $4;
      if ((f = $1->dn.function_num) != -1) {
        if (current_function_context)
          current_function_context->bindable = FP_NOT_BINDABLE;

        $$->kind = NODE_CALL_1;
        $$->v.number = F_CALL_FUNCTION_BY_ADDRESS;
        $$->l.number = f;
        $$->type = validate_function_call(f, $4->r.expr);
      } else if ((f=$1->dn.simul_num) != -1) {
        $$->kind = NODE_CALL_1;
        $$->v.number = F_SIMUL_EFUN;
        $$->l.number = f;
        $$->type = (SIMUL(f)->type) & ~DECL_MODS;
      } else if ((f=$1->dn.efun_num) != -1) {
        $$ = validate_efun_call(f, $4);
      } else {
        /* This here is a really nasty case that only occurs with
         * exact_types off.  The user has done something gross like:
         *
         * func() { int f; f(); } // if f was prototyped we wouldn't
         * f() { }                // need this case
         */
        if (exact_types) {
          char buf[256];
          char *end = EndOf(buf);
          char *p;
          const char *n = $1->name;
          if (*n == ':') n++;
          p = strput(buf, end, "Undefined function ");
          p = strput(p, end, n);
          yyerror(buf);
        } else {
          /*
           * Don't complain, just grok it.
           */
          if (current_function_context)
            current_function_context->bindable = FP_NOT_BINDABLE;

          f = define_new_function($1->name, 0, 0, DECL_PUBLIC|FUNC_UNDEFINED, TYPE_ANY);
          $$->kind = NODE_CALL_1;
          $$->v.number = F_CALL_FUNCTION_BY_ADDRESS;
          $$->l.number = f;
          $$->type = TYPE_ANY; /* just a guess */
        }
      }
      $$ = check_refs(num_refs - $<number>2, $4, $$);
      num_refs = $<number>2;
    }
  | function_name  '('
    {
      $<number>$ = context;
      $<number>2 = num_refs;
      context |= ARG_LIST;
    }
  expr_list ')'
    {
      char *name = $1;

      context = $<number>3;
      $$ = $4;

      if (current_function_context)
        current_function_context->bindable = FP_NOT_BINDABLE;

      if (*name == ':') {
        int f;

        if ((f = arrange_call_inherited(name + 1, $$)) != -1)
          /* Can't do this; f may not be the correct function
             entry.  It might be overloaded.

             validate_function_call(f, $$->r.expr)
             */
          ;
      } else {
        /* The only way this can happen is if function_name
         * below made the function name. (directly or inherited.)
         * The lexer would return L_DEFINED_NAME otherwise.
         */
        int f;
        ident_hash_elem_t *ihe;

        f = (ihe = lookup_ident(name)) ? ihe->dn.function_num : -1;

        // Funciton is not yet defined. for exact_types case, we simply return error,
        // otherwise attempt to create a function, hoping later it will be defined by inherit.
        if (f == -1) {
          if (exact_types) {
            char buf[256];
            char *end = EndOf(buf);
            char *p;
            char *n = $1;
            if (*n == ':') n++;
            p = strput(buf, end, "Undefined function ");
            p = strput(p, end, n);
            yyerror(buf);
          } else {
            f = define_new_function(name, 0, 0, DECL_PUBLIC|FUNC_UNDEFINED, TYPE_ANY);
          }
        }

        if (f != -1) {
          $$->kind = NODE_CALL_1;
          $$->v.number = F_CALL_FUNCTION_BY_ADDRESS;
          $$->l.number = f;
          if (FUNCTION_FLAGS(f) & FUNC_UNDEFINED) {
            $$->type = TYPE_ANY;  /* Just a guess */
          } else {
            $$->type = validate_function_call(f, $4->r.expr);
          }
        }
      }
      $$ = check_refs(num_refs - $<number>2, $4, $$);
      num_refs = $<number>2;
      scratch_free(name);
    }
  | expr4 L_ARROW identifier '('
    {
      $<number>$ = context;
      $<number>4 = num_refs;
      context |= ARG_LIST;
    }
  expr_list ')'
    {
      ident_hash_elem_t *ihe;
      int f;
      parse_node_t *pn1, *pn2;

      $6->v.number += 2;

      pn1 = new_node_no_line();
      pn1->type = 0;
      pn1->v.expr = $1;
      pn1->kind = $6->v.number;

      pn2 = new_node_no_line();
      pn2->type = 0;
      CREATE_STRING(pn2->v.expr, $3);
      scratch_free($3);

      /* insert the two nodes */
      pn2->r.expr = $6->r.expr;
      pn1->r.expr = pn2;
      $6->r.expr = pn1;

      if (!$6->l.expr) $6->l.expr = pn2;

      context = $<number>5;
      ihe = lookup_ident("call_other");

      if ((f = ihe->dn.simul_num) != -1) {
        $$ = $6;
        $$->kind = NODE_CALL_1;
        $$->v.number = F_SIMUL_EFUN;
        $$->l.number = f;
        $$->type = (SIMUL(f)->type) & ~DECL_MODS;
      } else {
        $$ = validate_efun_call(arrow_efun, $6);
#ifdef CAST_CALL_OTHERS
        $$->type = TYPE_UNKNOWN;
#else
        $$->type = TYPE_ANY;
#endif
      }
      $$ = check_refs(num_refs - $<number>4, $6, $$);
      num_refs = $<number>4;
    }
  | '(' '*' comma_expr ')' '('
    {
      $<number>$ = context;
      $<number>5 = num_refs;
      context |= ARG_LIST;
    }
  expr_list ')'
    {
      parse_node_t *expr;

      context = $<number>6;
      $$ = $7;
      $$->kind = NODE_EFUN;
      $$->l.number = $$->v.number + 1;
      $$->v.number = predefs[evaluate_efun].token;
#ifdef CAST_CALL_OTHERS
      $$->type = TYPE_UNKNOWN;
#else
      $$->type = TYPE_ANY;
#endif
      expr = new_node_no_line();
      expr->type = 0;
      expr->v.expr = $3;
      expr->r.expr = $$->r.expr;
      $$->r.expr = expr;
      $$ = check_refs(num_refs - $<number>5, $7, $$);
      num_refs = $<number>5;
    }
;

efun_override:
  L_EFUN L_COLON_COLON identifier
    {
      svalue_t *res;
      ident_hash_elem_t *ihe;

      $$ = (ihe = lookup_ident($3)) ? ihe->dn.efun_num : -1;
      if ($$ == -1) {
        yyerror("Unknown efun: %s", $3);
      } else {
        push_malloced_string(the_file_name(current_file));
        share_and_push_string($3);
        push_malloced_string(add_slash(main_file_name()));
        res = safe_apply_master_ob(APPLY_VALID_OVERRIDE, 3);
        if (!MASTER_APPROVED(res)) {
          yyerror("Invalid simulated efunction override");
          $$ = -1;
        }
      }
      scratch_free($3);
    }
  | L_EFUN L_COLON_COLON L_NEW
    {
      svalue_t *res;

      push_malloced_string(the_file_name(current_file));
      push_constant_string("new");
      push_malloced_string(add_slash(main_file_name()));
      res = safe_apply_master_ob(APPLY_VALID_OVERRIDE, 3);
      if (!MASTER_APPROVED(res)) {
        yyerror("Invalid simulated efunction override");
        $$ = -1;
      } else $$ = new_efun;
    }
;

function_name:
  L_IDENTIFIER
  | L_COLON_COLON identifier
    {
      int l = strlen($2) + 1;
      char *p;
      /* here we be a bit cute.  we put a : on the front so we
       * don't have to strchr for it.  Here we do:
       * "name" -> ":::name"
       */
      $$ = scratch_realloc($2, l + 3);
      p = $$ + l;
      while (p--,l--)
        *(p+3) = *p;
      strncpy($$, ":::", 3);
    }
  | L_BASIC_TYPE L_COLON_COLON identifier
    {
      int z, l = strlen($3) + 1;
      char *p;
      /* <type> and "name" -> ":type::name" */
      z = strlen(compiler_type_names[$1]) + 3; /* length of :type:: */
      $$ = scratch_realloc($3, l + z);
      p = $$ + l;
      while (p--,l--)
        *(p+z) = *p;
      $$[0] = ':';
      strncpy($$ + 1, compiler_type_names[$1], z - 3);
      $$[z-2] = ':';
      $$[z-1] = ':';
    }
  | identifier L_COLON_COLON identifier
    {
      int l = strlen($1);
      /* "ob" and "name" -> ":ob::name" */
      $$ = scratch_alloc(l + strlen($3) + 4);
      *($$) = ':';
      strcpy($$ + 1, $1);
      strcpy($$ + l + 1, "::");
      strcpy($$ + l + 3, $3);
      scratch_free($1);
      scratch_free($3);
    }
;

cond:
  L_IF '(' comma_expr ')' statement optional_else_part
    {
      /* x != 0 -> x */
      if (IS_NODE($3, NODE_BINARY_OP, F_NE)) {
        if (IS_NODE($3->r.expr, NODE_NUMBER, 0))
          $3 = $3->l.expr;
        else if (IS_NODE($3->l.expr, NODE_NUMBER, 0))
          $3 = $3->r.expr;
      }

      /* TODO: should optimize if (0), if (1) here.
       * Also generalize this.
       */

      if ($5 == 0) {
        if ($6 == 0) {
          /* if (x) ; -> x; */
          $$ = pop_value($3);
          break;
        } else {
          /* if (x) {} else y; -> if (!x) y; */
          parse_node_t *repl;

          CREATE_UNARY_OP(repl, F_NOT, TYPE_NUMBER, $3);
          $3 = repl;
          $5 = $6;
          $6 = 0;
        }
      }
      CREATE_IF($$, $3, $5, $6);
    }
;

optional_else_part:
  /* empty */  %empty %prec LOWER_THAN_ELSE
    {
      $$ = 0;
    }
  | L_ELSE statement
    {
      $$ = $2;
    }
;
%%
