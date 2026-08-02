package com.linkos.core.commandpalette

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.linkos.core.plugin.CommandPaletteAction
import com.linkos.ui.components.GlassCard
import com.linkos.ui.theme.*
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommandPaletteDialog(
    actions: List<CommandPaletteAction>,
    onDismissRequest: () -> Unit
) {
    var query by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    val filtered = remember(query, actions) {
        if (query.isEmpty()) actions else {
            val lower = query.lowercase()
            actions.filter {
                it.title.lowercase().contains(lower) ||
                (it.subtitle?.lowercase()?.contains(lower) == true) ||
                it.keywords.any { k -> k.lowercase().contains(lower) }
            }
        }
    }

    Dialog(onDismissRequest = onDismissRequest) {
        GlassCard(modifier = Modifier.fillMaxWidth().height(480.dp)) {
            Column(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // Search Input
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text("Search command or action...") },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = LinkOSBlue) },
                    trailingIcon = {
                        if (query.isNotEmpty()) {
                            IconButton(onClick = { query = "" }) {
                                Icon(Icons.Default.Close, contentDescription = "Clear")
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true
                )

                Divider(color = DarkSurfaceHighest)

                // Results list
                if (filtered.isEmpty()) {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No matching commands found", color = TextSecondary)
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(filtered, key = { it.id }) { action ->
                            Surface(
                                onClick = {
                                    scope.launch {
                                        action.action()
                                        onDismissRequest()
                                    }
                                },
                                color = DarkSurfaceElevated,
                                shape = MaterialTheme.shapes.small,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(action.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                                        if (action.subtitle != null) {
                                            Text(action.subtitle, style = MaterialTheme.typography.bodySmall, color = TextSecondary)
                                        }
                                    }

                                    AssistChip(
                                        onClick = {},
                                        label = { Text(action.category, style = MaterialTheme.typography.labelSmall) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
