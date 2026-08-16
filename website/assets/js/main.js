/**
 * Guardião X — script compartilhado por todas as páginas do site
 * institucional. Sem dependências externas: apenas menu mobile, ano
 * dinâmico do rodapé e marcação do link ativo na navegação.
 */
(function () {
  "use strict";

  // Menu mobile (hambúrguer)
  var toggle = document.querySelector(".nav-toggle");
  if (toggle) {
    toggle.addEventListener("click", function () {
      document.body.classList.toggle("nav-open");
      var expanded = document.body.classList.contains("nav-open");
      toggle.setAttribute("aria-expanded", String(expanded));
    });

    // Fecha o menu ao clicar em qualquer link (útil em navegação por âncora)
    document.querySelectorAll(".nav-links a").forEach(function (link) {
      link.addEventListener("click", function () {
        document.body.classList.remove("nav-open");
      });
    });
  }

  // Ano dinâmico no rodapé (evita "© 2026" desatualizado)
  document.querySelectorAll("[data-year]").forEach(function (el) {
    el.textContent = new Date().getFullYear();
  });

  // Marca o link do menu correspondente à página atual como ativo
  var currentPage = (window.location.pathname.split("/").pop() || "index.html").toLowerCase();
  document.querySelectorAll(".nav-links a[href]").forEach(function (link) {
    var href = link.getAttribute("href").split("#")[0].toLowerCase();
    if (href === currentPage || (href === "" && currentPage === "index.html")) {
      link.classList.add("active");
    }
  });
})();
